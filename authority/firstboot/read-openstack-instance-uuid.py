#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
AUTHORITY_DIR = SCRIPT_DIR.parent
sys.path.insert(0, str(AUTHORITY_DIR))

from authority_image.config_drive import ConfigDriveError, read_openstack_instance_uuid


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Read only the instance UUID from an OpenStack Config Drive."
    )
    parser.add_argument("--metadata-root", help="Mounted Config Drive root for tests/debugging.")
    args = parser.parse_args()

    try:
        evidence = read_openstack_instance_uuid(metadata_root=args.metadata_root)
    except ConfigDriveError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    print(json.dumps(evidence, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
