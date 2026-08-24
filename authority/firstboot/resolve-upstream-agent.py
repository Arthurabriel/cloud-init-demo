#!/usr/bin/env python3
"""Resolve the node SPIFFE ID of a specific attested SPIRE agent.

Picking the first row of `spire-server agent list` breaks as soon as a second Authority
attests to the same Trusted Root, or a reprovisioned one leaves its old agent behind: the
downstream entry gets parented to the wrong agent and looks perfectly valid while the new
Authority sits on "no identity issued".

Resolution order, most specific first:

1. an explicit node ID, still checked against the attested agents;
2. the parent of the alias entry created by `token generate -spiffeID <alias>`, accepted
   only when that parent is attested and not banned;
3. the only attested agent, when there is exactly one;
4. otherwise: fail and list the candidates.

Never guess. An agent chosen by accident produces an entry indistinguishable from a
correct one.
"""
from __future__ import annotations

import argparse
import json
import sys


def spiffe_id(value) -> str:
    """Normalize the string and {trust_domain, path} shapes SPIRE emits."""
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        trust_domain = value.get("trust_domain")
        path = value.get("path") or ""
        if trust_domain:
            path = path if str(path).startswith("/") else f"/{path}"
            return f"spiffe://{trust_domain}{path}"
    return ""


def load_json(path: str | None) -> dict:
    if not path:
        return {}
    try:
        with open(path, encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError, ValueError):
        return {}
    return payload if isinstance(payload, dict) else {}


def usable_agents(payload: dict) -> list[str]:
    """Attested agents that can still be parents: banned ones cannot."""
    agents = []
    for agent in payload.get("agents") or []:
        if agent.get("banned"):
            continue
        agent_id = spiffe_id(agent.get("id"))
        if agent_id:
            agents.append(agent_id)
    return agents


def alias_parents(payload: dict) -> list[str]:
    parents = []
    for entry in payload.get("entries") or []:
        parent = spiffe_id(entry.get("parent_id"))
        if parent:
            parents.append(parent)
    return parents


def fail(message: str, candidates: list[str], override_var: str) -> int:
    print(f"[resolve-agent] {message}", file=sys.stderr)
    if candidates:
        print("[resolve-agent] attested candidates:", file=sys.stderr)
        for candidate in candidates:
            print(f"[resolve-agent]   {candidate}", file=sys.stderr)
        print("[resolve-agent]", file=sys.stderr)
        print(
            f"[resolve-agent] Pick one explicitly and rerun with {override_var}=<id>.",
            file=sys.stderr,
        )
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--agents-json",
        required=True,
        help="File holding `spire-server agent list -output json`.",
    )
    parser.add_argument(
        "--alias-entries-json",
        help="File holding `spire-server entry show -spiffeID <alias> -output json`.",
    )
    parser.add_argument(
        "--expected-node-id",
        default="",
        help="Explicit node SPIFFE ID, validated against the attested agents.",
    )
    parser.add_argument(
        "--override-var",
        default="UPSTREAM_AGENT_NODE_SPIFFE_ID",
        help="Environment variable named in the failure message.",
    )
    args = parser.parse_args()

    agents = usable_agents(load_json(args.agents_json))
    if not agents:
        print(
            "[resolve-agent] no attested agent found. Start the agent and let it attest first.",
            file=sys.stderr,
        )
        return 1

    expected = args.expected_node_id.strip()
    if expected:
        if expected not in agents:
            return fail(
                f"{args.override_var} is not an attested agent: {expected}",
                agents,
                args.override_var,
            )
        print(expected)
        return 0

    # The alias entry created alongside the join token points at the exact agent. Only
    # trust it once the attested list confirms it, so a wrong assumption degrades into
    # the uniqueness check below instead of producing a bad parent.
    confirmed = [parent for parent in alias_parents(load_json(args.alias_entries_json)) if parent in agents]
    if len(set(confirmed)) == 1:
        print(confirmed[0])
        return 0

    if len(set(agents)) == 1:
        print(agents[0])
        return 0

    return fail(
        "cannot tell which agent belongs to this Authority.",
        sorted(set(agents)),
        args.override_var,
    )


if __name__ == "__main__":
    raise SystemExit(main())
