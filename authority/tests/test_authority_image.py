from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

AUTHORITY_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = AUTHORITY_DIR.parent
sys.path.insert(0, str(AUTHORITY_DIR))

from authority_image.config_drive import read_openstack_instance_uuid
from authority_image.manifest import build_manifest


class AuthorityImageTests(unittest.TestCase):
    def make_root(self) -> tempfile.TemporaryDirectory[str]:
        return tempfile.TemporaryDirectory(prefix="authority-root-")

    def write(self, root: Path, relative_path: str, content: str = "") -> Path:
        target = root / relative_path.lstrip("/")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        return target

    def populate_minimal_vm_root(self, root: Path) -> None:
        self.write(root, "/opt/spire/bin/spire-server", "#!/bin/sh\n")
        self.write(root, "/opt/spire/bin/spire-agent", "#!/bin/sh\n")
        self.write(root, "/etc/spire/server.conf", 'server {\n  trust_domain = "example.org"\n}\n')
        self.write(root, "/etc/spire/agent.conf", 'agent {\n  data_dir = "/var/lib/spire/agent"\n}\n')
        self.write(root, "/etc/systemd/system/spire-server.service")
        self.write(root, "/etc/systemd/system/spire-agent.service")
        self.write(root, "/etc/systemd/system/spire-evidence-adapter.service")
        self.write(root, "/opt/spire-demo/authority/scripts/authority-firstboot.sh", "#!/bin/sh\n")
        self.write(root, "/var/lib/spire/server/datastore.sqlite3", "server-db")
        self.write(root, "/var/lib/spire/server/datastore.sqlite3-wal", "wal")
        self.write(root, "/var/lib/spire/server/datastore.sqlite3-shm", "shm")
        self.write(root, "/var/lib/spire/server/datastore.sqlite3-journal", "journal")
        self.write(root, "/var/lib/spire/server/keys.json", '{"server":"key"}')
        self.write(root, "/var/lib/spire/agent/join-token", "old-token")
        self.write(root, "/var/lib/spire/agent/agent-spiffe-id", "spiffe://example.org/old-agent")
        self.write(root, "/var/lib/spire/agent/svid.der", "agent-state")
        self.write(root, "/var/lib/spire-demo/evidence/kv-store/identity.json", "{}")
        self.write(root, "/etc/spire-demo/agent.env", "GEMINI_API_KEY=secret\n")
        self.write(root, "/etc/machine-id", "machine-id\n")
        self.write(root, "/etc/ssh/ssh_host_ed25519_key", "host-key")
        self.write(root, "/var/lib/cloud/instance/meta-data.json", "{}")
        self.write(root, "/var/lib/cloud/instances/i-1/meta-data.json", "{}")
        self.write(root, "/var/lib/cloud/seed/config-drive/openstack/latest/meta_data.json", "{}")
        self.write(root, "/var/log/cloud-init.log", "old log")
        self.write(root, "/var/log/cloud-init-output.log", "old log")
        (root / "tmp").mkdir(exist_ok=True)
        (root / "var/tmp").mkdir(parents=True, exist_ok=True)
        self.write(root, "/tmp/tempfile", "temp")
        self.write(root, "/var/tmp/tempfile", "temp")

    def run_script(
        self,
        script: Path,
        root: Path,
        *args: str,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["AUTHORITY_ROOT"] = str(root)
        env["AUTHORITY_REPOSITORY_DIR"] = str(AUTHORITY_DIR)
        return subprocess.run(
            ["bash", str(script), *args],
            env=env,
            check=check,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_demo_bootstrap_sequence_is_preserved(self) -> None:
        bootstrap = (REPO_ROOT / "cloud-init-spire-instance/scripts/bootstrap.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('configure-spire-server.sh"', bootstrap)
        self.assertIn('configure-spire-agent.sh"', bootstrap)
        self.assertIn('configure-kv-workload.sh"', bootstrap)
        self.assertIn('configure-spire-evidence-adapter.sh"', bootstrap)
        self.assertIn('configure-spire-chat-agent.sh"', bootstrap)

    def test_prepare_removes_join_token_and_agent_state(self) -> None:
        with self.make_root() as root_name:
            root = Path(root_name)
            self.populate_minimal_vm_root(root)

            self.run_script(AUTHORITY_DIR / "scripts/prepare-authority-image.sh", root)

            self.assertFalse((root / "var/lib/spire/agent/join-token").exists())
            self.assertFalse((root / "var/lib/spire/agent/agent-spiffe-id").exists())
            self.assertEqual([], list((root / "var/lib/spire/agent").iterdir()))

    def test_prepare_preserves_spire_server_state(self) -> None:
        with self.make_root() as root_name:
            root = Path(root_name)
            self.populate_minimal_vm_root(root)

            self.run_script(AUTHORITY_DIR / "scripts/prepare-authority-image.sh", root)

            self.assertEqual(
                "server-db",
                (root / "var/lib/spire/server/datastore.sqlite3").read_text(encoding="utf-8"),
            )
            self.assertEqual(
                '{"server":"key"}',
                (root / "var/lib/spire/server/keys.json").read_text(encoding="utf-8"),
            )

    def test_prepare_finalize_removes_spire_server_runtime_state(self) -> None:
        with self.make_root() as root_name:
            root = Path(root_name)
            self.populate_minimal_vm_root(root)
            self.run_script(AUTHORITY_DIR / "scripts/prepare-authority-image.sh", root, "--finalize")

            server_dir = root / "var/lib/spire/server"
            self.assertTrue(server_dir.is_dir())
            self.assertEqual([], list(server_dir.iterdir()))
            self.assertFalse((root / "var/lib/spire/server/datastore.sqlite3").exists())
            self.assertFalse((root / "var/lib/spire/server/datastore.sqlite3-wal").exists())
            self.assertFalse((root / "var/lib/spire/server/datastore.sqlite3-shm").exists())
            self.assertFalse((root / "var/lib/spire/server/datastore.sqlite3-journal").exists())
            self.assertFalse((root / "var/lib/spire/server/keys.json").exists())

    def test_prepare_finalize_refuses_unknown_server_state(self) -> None:
        with self.make_root() as root_name:
            root = Path(root_name)
            self.populate_minimal_vm_root(root)
            self.write(root, "/var/lib/spire/server/unreviewed-state.bin", "unknown")

            result = self.run_script(
                AUTHORITY_DIR / "scripts/prepare-authority-image.sh",
                root,
                "--finalize",
                check=False,
            )

            self.assertNotEqual(0, result.returncode)
            self.assertTrue((root / "var/lib/spire/server/unreviewed-state.bin").exists())

    def test_check_rejects_prepare_without_finalize(self) -> None:
        with self.make_root() as root_name:
            root = Path(root_name)
            self.populate_minimal_vm_root(root)
            self.run_script(AUTHORITY_DIR / "scripts/prepare-authority-image.sh", root)

            result = self.run_script(
                AUTHORITY_DIR / "scripts/check-authority-image.sh",
                root,
                check=False,
            )

            self.assertNotEqual(0, result.returncode)
            self.assertIn("datastore antigo do SPIRE Server", result.stderr)

    def test_check_accepts_finalized_minimal_root(self) -> None:
        with self.make_root() as root_name:
            root = Path(root_name)
            self.populate_minimal_vm_root(root)
            self.run_script(AUTHORITY_DIR / "scripts/prepare-authority-image.sh", root, "--finalize")

            result = self.run_script(AUTHORITY_DIR / "scripts/check-authority-image.sh", root)

            self.assertIn("resultado: pronto", result.stdout)

    def test_authority_firstboot_is_linear_and_self_contained(self) -> None:
        firstboot_script = (AUTHORITY_DIR / "scripts/authority-firstboot.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("systemctl start spire-server", firstboot_script)
        self.assertIn("spire-server token generate", firstboot_script)
        self.assertIn("systemctl start spire-agent", firstboot_script)
        self.assertIn("systemctl restart spire-evidence-adapter", firstboot_script)
        self.assertNotIn("authority-agent-firstboot", firstboot_script)

    def test_authority_firstboot_cloud_init_is_minimal(self) -> None:
        user_data = (
            AUTHORITY_DIR / "cloud-init/authority-firstboot.yaml"
        ).read_text(encoding="utf-8")

        self.assertIn("authority-firstboot.sh", user_data)
        self.assertNotIn("git, clone", user_data)
        self.assertNotIn("install-spire", user_data)
        self.assertNotIn("bootstrap.sh", user_data)

    def test_authority_build_bootstrap_avoids_old_demo_join_token_flow(self) -> None:
        bootstrap = (AUTHORITY_DIR / "scripts/bootstrap-authority-image.sh").read_text(
            encoding="utf-8"
        )
        build_cloud_init = (
            AUTHORITY_DIR / "cloud-init/authority-build.yaml"
        ).read_text(encoding="utf-8")

        self.assertIn("install-docker.sh", bootstrap)
        self.assertIn("install-spire.sh", bootstrap)
        self.assertIn("authority-firstboot.sh", bootstrap)
        self.assertIn("bootstrap-authority-image.sh", build_cloud_init)
        self.assertIn("AUTHORITY_DIR", bootstrap)
        self.assertNotIn("cloud-init-spire-instance", bootstrap)
        self.assertNotIn("configure-spire-agent.sh", build_cloud_init)
        self.assertNotIn("configure-spire-agent.sh\"", bootstrap)
        self.assertNotIn("configure-kv-workload.sh\"", bootstrap)
        self.assertNotIn("configure-spire-chat-agent.sh\"", bootstrap)

    def test_manifest_can_be_generated(self) -> None:
        with self.make_root() as root_name:
            root = Path(root_name)
            self.populate_minimal_vm_root(root)

            manifest = build_manifest(
                root=root,
                repository_dir=AUTHORITY_DIR,
                authority_config=AUTHORITY_DIR / "config/authority.env",
                generated_at="2026-08-10T00:00:00Z",
            )

            self.assertEqual("1.0", manifest["schema_version"])
            self.assertEqual("pgid-authority", manifest["authority"]["name"])
            self.assertEqual("0.1.0", manifest["authority"]["version"])
            self.assertEqual("example.org", manifest["authority"]["trust_domain"])
            self.assertTrue(manifest["components"]["spire_server"])
            self.assertTrue(manifest["components"]["authority_firstboot_script"])
            self.assertEqual("1.15.1", manifest["spire"]["version"])

    def test_config_drive_exposes_only_instance_uuid(self) -> None:
        with tempfile.TemporaryDirectory(prefix="config-drive-") as metadata_root_name:
            metadata_root = Path(metadata_root_name)
            metadata_file = metadata_root / "openstack/latest/meta_data.json"
            metadata_file.parent.mkdir(parents=True)
            metadata_file.write_text(
                json.dumps(
                    {
                        "uuid": "30debd02-4a1a-4e92-8f9c-4b779fa38a1e",
                        "admin_pass": "secret",
                        "random_seed": "seed",
                        "public_keys": {"default": "ssh-rsa AAAA"},
                    }
                ),
                encoding="utf-8",
            )

            evidence = read_openstack_instance_uuid(metadata_root=metadata_root)

            self.assertEqual(
                {
                    "instance_uuid": "30debd02-4a1a-4e92-8f9c-4b779fa38a1e",
                    "evidence_source": "openstack-config-drive",
                },
                evidence,
            )
            self.assertNotIn("admin_pass", evidence)
            self.assertNotIn("random_seed", evidence)
            self.assertNotIn("public_keys", evidence)


if __name__ == "__main__":
    unittest.main()
