#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
AUTHORITY_DIR = SCRIPT_DIR.parent
sys.path.insert(0, str(AUTHORITY_DIR))

from authority_image.manifest import main


if __name__ == "__main__":
    raise SystemExit(main())
