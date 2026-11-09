#!/usr/bin/env python3
"""Groepeert een Terraform plan-JSON per bronbestand voor Rover.

Rover groepeert op module, niet op bestand. Dit script verplaatst elke
resource naar een synthetische module met de naam van het .tf-bestand.
Zo tekent Rover kaders per bestand, met de verwijzingen ertussen.
De echte Terraform-configuratie wordt niet aangepast.
"""

from __future__ import annotations

import copy
import json
import re
import sys
from pathlib import Path

import hcl2

INFRA = Path("infra")


def slug(name: str) -> str:
    return re.sub(r"[^a-z0-9_]", "_", name.lower())


def file_map() -> dict[tuple[str, str], str]:
    mapping: dict[tuple[str, str], str] = {}
    for path in sorted(INFRA.glob("*.tf")):
        data = hcl2.loads(path.read_text(encoding="utf-8"))
        for block in data.get("resource", []):
            for rtype, entries in block.items():
                for rname in entries:
                    mapping[(rtype.strip('"'), rname.strip('"'))] = path.stem
    return mapping


def prefix(module: dict, mapping: dict[tuple[str, str], str]) -> None:
    groups: dict[str, list[dict]] = {}
    keep: list[dict] = []
    for resource in module.get("resources", []):
        source = mapping.get((resource.get("type", ""), resource.get("name", "")))
        if not source:
            keep.append(resource)
            continue
        groups.setdefault(source, []).append(resource)
    module["resources"] = keep

    children = module.setdefault("child_modules", [])
    for source, resources in groups.items():
        address = f"module.{slug(source)}"
        for resource in resources:
            resource["address"] = f"{address}.{resource['address']}"
        children.append({"address": address, "resources": resources})


def prefix_config(root: dict, mapping: dict[tuple[str, str], str]) -> dict[str, str]:
    """Houdt de configuratie plat, maar geeft resources een module-adres.

    Rover bouwt randen uit de configuratie. Door de configuratie plat te
    houden (geen module_calls) en de adressen te prefixen, kan hij de
    verwijzingen naar andere bestanden wel leggen.
    """
    replacements: dict[str, str] = {}
    for resource in root.get("resources", []):
        source = mapping.get((resource.get("type", ""), resource.get("name", "")))
        if not source:
            continue
        new_address = f"module.{slug(source)}.{resource['address']}"
        replacements[resource["address"]] = new_address
        resource["address"] = new_address
    return replacements


def rewrite(value, replacements: dict[str, str]):
    if isinstance(value, str):
        for old, new in replacements.items():
            value = re.sub(rf"(?<![\w.]){re.escape(old)}(?![\w])", new, value)
        return value
    if isinstance(value, list):
        return [rewrite(v, replacements) for v in value]
    if isinstance(value, dict):
        return {k: rewrite(v, replacements) for k, v in value.items()}
    return value


def main() -> int:
    if len(sys.argv) < 2:
        print("Gebruik: python3 scripts/rover_file_map.py plan.json", file=sys.stderr)
        return 1

    plan = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    mapping = file_map()
    p = copy.deepcopy(plan)

    prefix(p.get("planned_values", {}).get("root_module", {}), mapping)
    prefix(p.get("prior_state", {}).get("values", {}).get("root_module", {}), mapping)

    changes = []
    for change in p.get("resource_changes", []):
        source = mapping.get((change.get("type", ""), change.get("name", "")))
        if source:
            name = slug(source)
            change["module_address"] = f"module.{name}"
            change["address"] = f"module.{name}.{change['address']}"
        changes.append(change)
    p["resource_changes"] = changes

    config = p.get("configuration", {}).get("root_module", {})
    replacements = prefix_config(config, mapping)
    p["configuration"] = rewrite(p.get("configuration", {}), replacements)

    out = Path("plan-files.json")
    out.write_text(json.dumps(p), encoding="utf-8")
    files = sorted({slug(v) for v in mapping.values()})
    print(f"bestanden: {', '.join(files)}")
    print(f"{len(changes)} resources -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
