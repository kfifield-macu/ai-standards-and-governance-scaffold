#!/usr/bin/env python3
"""Validate the scaffold: schemas plus the cross-file rules from the standard.

Usage: python3 -I scripts/validate.py   (run from anywhere; paths resolve from the repo root)
Requires: pyyaml, jsonschema
Exit code 0 = valid, 1 = errors.

Note: CEL expressions are checked for presence only, not evaluated. Evaluation belongs
to the enforcer (see README, conformance level L3).
"""
import json
import re
import sys
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parent.parent
errors: list[str] = []

SECRET_PATTERNS = {
    "aws-access-key": r"AKIA[0-9A-Z]{16}",
    "github-token": r"gh[pousr]_[A-Za-z0-9]{30,}",
    "slack-token": r"xox[baprs]-[A-Za-z0-9-]{10,}",
    "private-key": r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
    "generic-assignment": r"(?i)(api[_-]?key|secret|token|password)\s*[:=]\s*['\"]?[A-Za-z0-9/+_\-]{16,}",
}


def err(path: Path | str, msg: str) -> None:
    errors.append(f"{path}: {msg}")


def rel(p: Path) -> str:
    return str(p.relative_to(ROOT))


def load_yaml(p: Path):
    try:
        return yaml.safe_load(p.read_text())
    except yaml.YAMLError as e:
        err(rel(p), f"invalid YAML: {e}")
        return None


def schema_check(p: Path, schema_name: str):
    data = load_yaml(p)
    if data is None:
        return None
    schema = json.loads((ROOT / "schemas" / schema_name).read_text())
    for e in sorted(Draft202012Validator(schema).iter_errors(data), key=lambda e: list(e.path)):
        loc = ".".join(str(x) for x in e.path) or "<root>"
        err(rel(p), f"{loc}: {e.message}")
    return data


def front_matter(p: Path) -> dict:
    text = p.read_text()
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    return (yaml.safe_load(m.group(1)) or {}) if m else {}


def main() -> int:
    # --- Global invariants + tool descriptors -----------------------------------------
    inv = schema_check(ROOT / "permissions/invariants.yaml", "invariants.schema.json") or {}
    denied_paths = set(inv.get("secrets", {}).get("denied_paths", []))
    denied_ops = set(inv.get("secrets", {}).get("denied_operations", []))

    tools: dict[str, dict] = {}
    for p in sorted((ROOT / "permissions/tools").glob("*.yaml")):
        d = schema_check(p, "tool-descriptor.schema.json")
        if not d:
            continue
        tools[d["name"]] = d
        # Rule: every declared credential store is automatically denied.
        denied_paths.update(d["auth"]["store_paths"])
        for op in d["operations"]:
            if f"{d['name']}.{op['name']}" in denied_ops:
                err(rel(p), f"operation {op['name']} is globally denied by the secrets invariant")

    # --- Org defaults (ceiling) --------------------------------------------------------
    org = schema_check(ROOT / "permissions/org-defaults.yaml", "permissions.schema.json") or {}
    schema_check(ROOT / "governors/org-defaults.yaml", "governor.schema.json")
    org_ops = {(t["tool"], o) for t in org.get("tools", []) for o in t["operations"]}

    tiers = (yaml.safe_load((ROOT / "models/tiers.yaml").read_text()) or {}).get("tiers", {})

    # --- Capabilities -------------------------------------------------------------------
    for p in sorted((ROOT / "capabilities").glob("*.yaml")):
        cap = schema_check(p, "capability.schema.json")
        if not cap:
            continue
        name = cap["name"]
        if p.stem != name:
            err(rel(p), f"file name must match capability name '{name}'")
        if not cap["owner"].strip():
            err(rel(p), "owner is required. Nobody has decided this.")
        if cap["model"]["tier"] not in tiers:
            err(rel(p), f"tier {cap['model']['tier']} missing from models/tiers.yaml")
        obs = cap["observability"]
        if obs["content_capture"] and not (obs.get("retention_days") and obs.get("redact")):
            err(rel(p), "content_capture requires retention_days and redact: true")

        # Evals required at L2+.
        if cap["conformance"] in ("L2", "L3"):
            ev = cap.get("evals")
            ev_dir = ROOT / ev if ev else None
            if not ev_dir or not ev_dir.is_dir():
                err(rel(p), f"{cap['conformance']} requires an evals directory")
            else:
                files = list(ev_dir.glob("*.yaml"))
                if not files:
                    err(rel(p), "evals directory is empty")
                for f in files:
                    schema_check(f, "eval.schema.json")

        # Referenced files exist and validate.
        for key, schema in (("governor", "governor.schema.json"), ("permissions", "permissions.schema.json")):
            f = ROOT / cap[key]
            if not f.is_file():
                err(rel(p), f"{key} file not found: {cap[key]}")
        ctx = ROOT / cap["context"]
        if not ctx.is_file():
            err(rel(p), f"context file not found: {cap['context']}")
        gov_path, perm_path = ROOT / cap["governor"], ROOT / cap["permissions"]
        if gov_path.is_file():
            schema_check(gov_path, "governor.schema.json")
        perm = schema_check(perm_path, "permissions.schema.json") if perm_path.is_file() else None

        # Auth profiles must be references to profiles that exist.
        for ref in cap.get("auth", {}).get("profiles", []):
            tool, prof = ref.removeprefix("profile:").split("/")
            if prof not in tools.get(tool, {}).get("auth", {}).get("profiles", []):
                err(rel(p), f"auth profile {ref} not declared by any tool descriptor")

        if not perm:
            continue

        # Narrow-only: capability may not widen the org ceiling.
        for t in perm["tools"]:
            if t["tool"] not in tools:
                err(rel(perm_path), f"unknown tool {t['tool']}")
                continue
            known = {o["name"] for o in tools[t["tool"]]["operations"]}
            for o in t["operations"]:
                if o not in known:
                    err(rel(perm_path), f"{t['tool']}.{o} is not in the tool descriptor")
                if (t["tool"], o) not in org_ops:
                    err(rel(perm_path), f"{t['tool']}.{o} widens org-defaults")
                if f"{t['tool']}.{o}" in denied_ops:
                    err(rel(perm_path), f"{t['tool']}.{o} is denied by the secrets invariant")
        org_egress = set(org.get("network", {}).get("egress", []))
        for host in perm.get("network", {}).get("egress", []):
            if host not in org_egress:
                err(rel(perm_path), f"egress {host} widens org-defaults")
        org_src = set(org.get("attach_sources", []))
        for s in perm.get("attach_sources", []):
            if s not in org_src:
                err(rel(perm_path), f"attach source {s} widens org-defaults")
        org_write = set(org.get("paths", {}).get("write", []))
        for w in perm.get("paths", {}).get("write", []):
            if w not in org_write:
                err(rel(perm_path), f"write path {w} widens org-defaults")
        for kind in ("read", "write"):
            for path in perm.get("paths", {}).get(kind, []):
                if path in denied_paths:
                    err(rel(perm_path), f"path {path} is denied by the secrets invariant")

        # Context may only attach sources the permissions allow.
        if ctx.is_file():
            for s in front_matter(ctx).get("attach", []):
                if s not in perm.get("attach_sources", []):
                    err(rel(ctx), f"attaches '{s}' but permissions do not allow it")

    # --- No secret-looking literals anywhere ---------------------------------------------
    for p in ROOT.rglob("*"):
        if not p.is_file() or p.suffix not in {".yaml", ".yml", ".md", ".json"} or "scripts" in p.parts:
            continue
        text = p.read_text(errors="ignore")
        for label, pat in SECRET_PATTERNS.items():
            if re.search(pat, text):
                err(rel(p), f"possible secret literal ({label}). References only, never values.")

    for e in errors:
        print(f"ERROR {e}")
    print(f"\n{'FAILED' if errors else 'OK'}: {len(errors)} error(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
