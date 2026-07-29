#!/usr/bin/env python3
"""Compare certified fixture bytes to their manifest; update hashes only by explicit opt-in."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path


class FixtureError(RuntimeError):
    pass


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def load_inventory(path: Path) -> dict:
    try:
        inventory = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FixtureError(f"cannot read fixture inventory {path}: {error}") from error
    if inventory.get("schemaVersion") != 1 or not isinstance(inventory.get("fixtures"), list):
        raise FixtureError(f"{path}: expected schemaVersion 1 and a fixtures array")
    return inventory


def fixture_path(root: Path, value: object, fixture_id: object) -> Path:
    if not isinstance(value, str) or not value or Path(value).is_absolute():
        raise FixtureError(f"{fixture_id}: path must be a non-empty relative path")
    resolved_root = root.resolve()
    resolved = (root / value).resolve()
    if resolved_root not in (resolved, *resolved.parents):
        raise FixtureError(f"{fixture_id}: fixture path escapes inventory directory")
    return resolved


def compare_or_update(inventory_path: Path, update: bool) -> list[str]:
    inventory = load_inventory(inventory_path)
    errors: list[str] = []
    fixtures = inventory["fixtures"]
    seen: set[str] = set()
    changed = False
    for fixture in fixtures:
        if not isinstance(fixture, dict):
            errors.append("fixture entry must be an object")
            continue
        fixture_id = fixture.get("id")
        if not isinstance(fixture_id, str) or not fixture_id:
            errors.append("fixture id must be a non-empty string")
            continue
        if fixture_id in seen:
            errors.append(f"{fixture_id}: duplicate fixture id")
            continue
        seen.add(fixture_id)
        if not isinstance(fixture.get("license"), str) or not fixture["license"]:
            errors.append(f"{fixture_id}: missing license")
        if not isinstance(fixture.get("provenance"), str) or not fixture["provenance"]:
            errors.append(f"{fixture_id}: missing provenance")
        try:
            path = fixture_path(inventory_path.parent, fixture.get("path"), fixture_id)
        except FixtureError as error:
            errors.append(str(error))
            continue
        if not path.is_file():
            errors.append(f"{fixture_id}: missing fixture file {path}")
            continue
        observed = digest(path)
        expected = fixture.get("sha256")
        if not isinstance(expected, str) or len(expected) != 64 or any(char not in "0123456789abcdef" for char in expected):
            errors.append(f"{fixture_id}: sha256 must be a lowercase SHA-256 hex digest")
            continue
        if observed != expected:
            if update:
                fixture["sha256"] = observed
                changed = True
            else:
                errors.append(f"{fixture_id}: SHA-256 differs (expected {expected}, observed {observed}); regenerate deliberately and use FILECONVERT_UPDATE_FIXTURES=1 with --update")
    if not fixtures:
        errors.append("fixture inventory is empty")
    if errors:
        return errors
    if changed:
        temporary = inventory_path.with_suffix(inventory_path.suffix + ".tmp")
        temporary.write_text(json.dumps(inventory, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        temporary.replace(inventory_path)
        print(f"updated fixture hashes in {inventory_path}")
    else:
        print(f"fixture inventory compares cleanly: {inventory_path}")
    return []


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update", action="store_true", help="write observed hashes after fixtures were deliberately regenerated")
    parser.add_argument("inventory", type=Path)
    args = parser.parse_args()
    if args.update and os.environ.get("FILECONVERT_UPDATE_FIXTURES") != "1":
        parser.error("--update requires FILECONVERT_UPDATE_FIXTURES=1; default mode never writes fixtures or manifests")
    try:
        errors = compare_or_update(args.inventory, args.update)
    except FixtureError as error:
        errors = [str(error)]
    if errors:
        for error in errors:
            print(f"fixture check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
