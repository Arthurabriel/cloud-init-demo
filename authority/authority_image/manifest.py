"""Generate the PGID Authority image manifest."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


def _read_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def _run(command: list[str], cwd: Path | None = None) -> str | None:
    try:
        result = subprocess.run(
            command,
            cwd=str(cwd) if cwd else None,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    output = result.stdout.strip()
    return output or None


def _trust_domain_from_config(path: Path) -> str | None:
    if not path.exists():
        return None
    match = re.search(
        r'^\s*trust_domain\s*=\s*"([^"]+)"\s*$',
        path.read_text(encoding="utf-8"),
        flags=re.MULTILINE,
    )
    return match.group(1) if match else None


def _spire_version(root: Path, repository_dir: Path) -> str | None:
    binary = root / "opt/spire/bin/spire-server"
    version = _run([str(binary), "--version"]) if binary.exists() else None
    if version:
        return version.splitlines()[-1].strip()

    version_env = _read_env_file(repository_dir / "config/version.env")
    return version_env.get("SPIRE_VERSION")


def _docker_repo_digest(image: str | None) -> str | None:
    if not image:
        return None
    digest = _run(["docker", "image", "inspect", image, "--format", "{{index .RepoDigests 0}}"])
    return digest


def _git_commit(repository_dir: Path) -> str | None:
    return _run(["git", "rev-parse", "HEAD"], cwd=repository_dir)


def build_manifest(
    root: Path,
    repository_dir: Path,
    authority_config: Path,
    generated_at: str | None = None,
) -> dict[str, Any]:
    runtime = _read_env_file(repository_dir / "config/runtime.env")
    authority = _read_env_file(authority_config)
    server_config = root / "etc/spire/server.conf"
    if not server_config.exists():
        server_config = repository_dir / "config/server.conf"

    evidence_image = runtime.get("SPIRE_EVIDENCE_ADAPTER_IMAGE")
    chat_image = runtime.get("SPIRE_CHAT_AGENT_IMAGE")
    kv_image = runtime.get("KEY_STORE_IMAGE_REF") or runtime.get("KEY_STORE_IMAGE")

    return {
        "schema_version": authority.get("AUTHORITY_SCHEMA_VERSION", "1.0"),
        "authority": {
            "name": authority.get("AUTHORITY_NAME"),
            "version": authority.get("AUTHORITY_VERSION"),
            "image_name": authority.get("AUTHORITY_IMAGE_NAME"),
            "trust_domain": _trust_domain_from_config(server_config),
        },
        "spire": {
            "version": _spire_version(root, repository_dir),
        },
        "components": {
            "spire_server": (root / "etc/systemd/system/spire-server.service").exists()
            or (repository_dir / "systemd/spire-server.service").exists(),
            "spire_agent": (root / "etc/systemd/system/spire-agent.service").exists()
            or (repository_dir / "systemd/spire-agent.service").exists(),
            "evidence_service": (root / "etc/systemd/system/spire-evidence-adapter.service").exists()
            or (repository_dir / "systemd/spire-evidence-adapter.service").exists(),
            "authority_firstboot_script": (
                root / "opt/spire-demo/authority/firstboot/authority-firstboot.sh"
            ).exists()
            or (Path(__file__).resolve().parents[1] / "firstboot/authority-firstboot.sh").exists(),
            "demo_kv_store": (root / "etc/systemd/system/kv-store.service").exists()
            or (repository_dir / "systemd/kv-store.service").exists(),
            "demo_chat_agent": (root / "etc/systemd/system/spire-chat-agent.service").exists()
            or (repository_dir / "systemd/spire-chat-agent.service").exists(),
        },
        "containers": {
            "evidence_service": {
                "image": evidence_image,
                "digest": _docker_repo_digest(evidence_image),
            },
            "demo_kv_store": {
                "image": kv_image,
                "digest": _docker_repo_digest(kv_image),
            },
            "demo_chat_agent": {
                "image": chat_image,
                "digest": _docker_repo_digest(chat_image),
            },
        },
        "build": {
            "git_commit": _git_commit(repository_dir),
            "generated_at": generated_at
            or datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate authority-manifest.json")
    parser.add_argument("--root", default=os.getenv("AUTHORITY_ROOT", "/"))
    parser.add_argument(
        "--repository-dir",
        default=os.getenv("AUTHORITY_REPOSITORY_DIR", "/opt/spire-demo/authority"),
    )
    parser.add_argument(
        "--authority-config",
        default=os.getenv(
            "AUTHORITY_CONFIG",
            str(Path(__file__).resolve().parents[1] / "config/authority.env"),
        ),
    )
    parser.add_argument("--output", default="authority-manifest.json")
    args = parser.parse_args()

    manifest = build_manifest(
        root=Path(args.root),
        repository_dir=Path(args.repository_dir),
        authority_config=Path(args.authority_config),
    )
    Path(args.output).write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
