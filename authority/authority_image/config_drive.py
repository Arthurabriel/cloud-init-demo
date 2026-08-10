"""Read safe local evidence from an OpenStack Config Drive.

Only the instance UUID is exposed. The full metadata document can contain
admin passwords, random seeds, SSH keys, and user data, so callers must not
return or log it.
"""

from __future__ import annotations

import json
import os
import subprocess
from collections.abc import Callable, Sequence
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any

CONFIG_DRIVE_LABEL = "config-2"
METADATA_PATH = Path("openstack/latest/meta_data.json")
EVIDENCE_SOURCE = "openstack-config-drive"

CommandRunner = Callable[[Sequence[str]], subprocess.CompletedProcess[str]]


class ConfigDriveError(RuntimeError):
    """Raised when Config Drive metadata is malformed or inaccessible."""


def _run(command: Sequence[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(command),
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def _safe_uuid_from_metadata(metadata: dict[str, Any]) -> str | None:
    instance_uuid = metadata.get("uuid")
    if isinstance(instance_uuid, str) and instance_uuid.strip():
        return instance_uuid.strip()
    return None


def read_instance_uuid_from_metadata_root(metadata_root: str | os.PathLike[str]) -> dict[str, str | None]:
    """Read only the OpenStack instance UUID from a mounted Config Drive path."""
    metadata_file = Path(metadata_root) / METADATA_PATH
    try:
        metadata = json.loads(metadata_file.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ConfigDriveError(f"metadata file not found: {metadata_file}") from exc
    except json.JSONDecodeError as exc:
        raise ConfigDriveError(f"metadata file is not valid JSON: {metadata_file}") from exc

    if not isinstance(metadata, dict):
        raise ConfigDriveError(f"metadata file is not a JSON object: {metadata_file}")

    return {
        "instance_uuid": _safe_uuid_from_metadata(metadata),
        "evidence_source": EVIDENCE_SOURCE,
    }


def find_mounted_config_drive(
    mounts_file: str | os.PathLike[str] = "/proc/mounts",
) -> Path | None:
    """Return the mount point for an already mounted OpenStack Config Drive."""
    try:
        lines = Path(mounts_file).read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return None

    for line in lines:
        fields = line.split()
        if len(fields) < 3:
            continue
        device, mount_point, filesystem = fields[:3]
        if filesystem != "iso9660":
            continue
        if device == "/dev/disk/by-label/config-2" or device.endswith("/config-2"):
            return Path(mount_point.replace("\\040", " "))
        candidate = Path(mount_point.replace("\\040", " ")) / METADATA_PATH
        if candidate.exists():
            return candidate.parents[2]
    return None


def find_config_drive_device(
    runner: CommandRunner = _run,
) -> str | None:
    """Find the block device with LABEL=config-2."""
    result = runner(["blkid", "-L", CONFIG_DRIVE_LABEL])
    if result.returncode == 0:
        device = result.stdout.strip()
        if device:
            return device

    by_label = Path("/dev/disk/by-label") / CONFIG_DRIVE_LABEL
    if by_label.exists():
        return str(by_label)
    return None


def read_openstack_instance_uuid(
    metadata_root: str | os.PathLike[str] | None = None,
    runner: CommandRunner = _run,
) -> dict[str, str | None]:
    """Return local OpenStack instance UUID evidence without exposing metadata.

    If metadata_root is provided, it is treated as an already mounted Config
    Drive root. Otherwise, the function checks existing mounts and then mounts
    LABEL=config-2 read-only into a temporary directory when needed.
    """
    if metadata_root is not None:
        return read_instance_uuid_from_metadata_root(metadata_root)

    mounted_root = find_mounted_config_drive()
    if mounted_root is not None:
        return read_instance_uuid_from_metadata_root(mounted_root)

    device = find_config_drive_device(runner=runner)
    if device is None:
        return {"instance_uuid": None, "evidence_source": EVIDENCE_SOURCE}

    with TemporaryDirectory(prefix="openstack-config-drive-") as mount_dir:
        mount_result = runner(["mount", "-o", "ro", device, mount_dir])
        if mount_result.returncode != 0:
            raise ConfigDriveError(
                f"failed to mount Config Drive {device}: {mount_result.stderr.strip()}"
            )
        try:
            return read_instance_uuid_from_metadata_root(mount_dir)
        finally:
            runner(["umount", mount_dir])
