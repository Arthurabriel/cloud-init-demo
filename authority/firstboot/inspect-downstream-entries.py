#!/usr/bin/env python3
"""Classify `spire-server entry show -output json` rows for a downstream registration.

Reads the JSON on stdin and prints one tab-separated row per entry:

    MATCH|STALE <entry id> <parent id> <selectors> downstream=<bool>

A leftover entry from a previous join token keeps the same SPIFFE ID but points at a
dead parent, which leaves a freshly provisioned Authority stuck on "no identity issued".
Only an entry whose parent, selector and downstream flag all match is a MATCH.
"""
from __future__ import annotations

import argparse
import json
import sys


def spiffe_id(value) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        trust_domain = value.get("trust_domain")
        path = value.get("path") or ""
        if trust_domain:
            path = path if str(path).startswith("/") else f"/{path}"
            return f"spiffe://{trust_domain}{path}"
    return ""


def selectors(entry: dict) -> list[str]:
    out = []
    for selector in entry.get("selectors") or []:
        if isinstance(selector, dict):
            out.append(f"{selector.get('type')}:{selector.get('value')}")
        elif isinstance(selector, str):
            out.append(selector)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-parent", required=True)
    parser.add_argument("--expected-selector", required=True)
    args = parser.parse_args()

    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    for entry in payload.get("entries") or []:
        parent = spiffe_id(entry.get("parent_id"))
        entry_selectors = selectors(entry)
        downstream = bool(entry.get("downstream"))
        matches = (
            parent == args.expected_parent
            and args.expected_selector in entry_selectors
            and downstream
        )
        print(
            "\t".join(
                [
                    "MATCH" if matches else "STALE",
                    entry.get("id") or "",
                    parent or "<none>",
                    ",".join(entry_selectors) or "<none>",
                    f"downstream={str(downstream).lower()}",
                ]
            )
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
