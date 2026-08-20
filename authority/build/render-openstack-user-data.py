#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path


AUTHORITY_DIR = Path(__file__).resolve().parents[1]


def replace_env_line(text: str, key: str, value: str) -> str:
    return re.sub(
        rf"(^      {re.escape(key)}=).*$",
        rf"\g<1>{value}",
        text,
        flags=re.MULTILINE,
    )


def extract_join_token(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("Token:"):
            parts = stripped.split()
            if len(parts) >= 2:
                return parts[1]
        return stripped
    raise SystemExit(f"join token file is empty: {path}")


def add_upstream_join_token(text: str, token: str) -> str:
    block = (
        "  - path: /etc/pgid-authority/upstream-agent.join-token\n"
        "    owner: root:spire-agent\n"
        "    permissions: '0640'\n"
        "    content: |\n"
        f"      {token}\n"
        "\n"
    )
    return text.replace("\nruncmd:\n", f"\n{block}runcmd:\n")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Render OpenStack cloud-init user-data for PGID Nested SPIRE VMs."
    )
    parser.add_argument("--role", choices=["trusted-root", "authority"], required=True)
    parser.add_argument("--trust-domain", default="example.org")
    parser.add_argument("--trusted-server", help="Trusted Root address for the Authority VM.")
    parser.add_argument("--trusted-port", default="8081")
    parser.add_argument(
        "--upstream-join-token-file",
        type=Path,
        help="File containing the short-lived join token generated on the Trusted Root.",
    )
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if args.role == "trusted-root":
        template = AUTHORITY_DIR / "cloud-init/trusted-root-firstboot.yaml"
    else:
        template = AUTHORITY_DIR / "cloud-init/nested-authority-firstboot.yaml"
        if not args.trusted_server:
            raise SystemExit("--trusted-server is required for --role authority")

    text = template.read_text(encoding="utf-8")
    text = replace_env_line(text, "TRUST_DOMAIN", args.trust_domain)

    if args.role == "authority":
        text = replace_env_line(text, "TRUSTED_SPIRE_SERVER", args.trusted_server or "")
        text = replace_env_line(text, "TRUSTED_SPIRE_PORT", args.trusted_port)
        if args.upstream_join_token_file:
            text = add_upstream_join_token(
                text,
                extract_join_token(args.upstream_join_token_file),
            )

    args.output.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
