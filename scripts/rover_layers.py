#!/usr/bin/env python3
"""Splitst een Terraform plan-JSON in leesbare lagen voor Rover.

Rover tekent alles uit prior_state, planned_values en configuration. Een
gerichte `terraform plan -target` helpt daarom niet: de prior state bevat
alsnog alle resources. Dit script filtert alle drie de onderdelen op
resource-type (en waar nodig op naam), zodat Rover per laag een kleine
graaf tekent.

Gebruik:
    python3 scripts/rover_layers.py plan.json
"""

from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

OUT = Path("rover-plans")

# Per laag: type-prefixen, of "type:naam" voor een specifieke resource.
LAYERS = {
    "netwerk": [
        "aws_vpc", "aws_subnet", "=aws_ec2_transit_gateway",
        "=aws_ec2_transit_gateway_vpc_attachment", "aws_nat_gateway",
        "aws_internet_gateway", "aws_route53_zone",
    ],
    "beveiliging": [
        "aws_security_group", "aws_key_pair", "aws_lambda_function",
        "=aws_api_gateway_rest_api", "aws_dynamodb_table",
    ],
    "websites": [
        "aws_instance:workload", "aws_lb", "aws_key_pair",
    ],
    "databases": [
        "aws_rds_cluster", "aws_rds_cluster_instance", "aws_db_subnet_group",
        "aws_secretsmanager_secret",
    ],
    "soar": [
        "aws_ecs_cluster", "aws_ecs_service", "aws_ecs_task_definition",
        "aws_lb", "aws_sqs_queue", "aws_cloudwatch_event_rule",
        "aws_lambda_function", "=aws_api_gateway_rest_api",
        "aws_dynamodb_table", "aws_sns_topic",
    ],
    "observability": [
        "aws_instance:observability", "aws_cloudwatch_metric_alarm",
        "aws_cloudwatch_log_group", "aws_route53_record", "aws_flow_log",
    ],
    "opslag": [
        "aws_s3_bucket",
    ],
}


def matches(resource: dict, spec: list[str]) -> bool:
    rtype = resource.get("type", "")
    rname = resource.get("name", "")
    for item in spec:
        if item.startswith("="):
            if rtype == item[1:]:
                return True
        elif ":" in item:
            want_type, want_name = item.split(":", 1)
            if rtype == want_type and rname == want_name:
                return True
        elif rtype == item or rtype.startswith(item):
            return True
    return False


def filter_module(module: dict, spec: list[str]) -> None:
    if not module:
        return
    module["resources"] = [r for r in module.get("resources", []) if matches(r, spec)]
    for child in module.get("child_modules", []) or []:
        filter_module(child, spec)


def split(plan: dict, spec: list[str]) -> dict:
    p = copy.deepcopy(plan)

    prior = p.get("prior_state", {}).get("values", {})
    filter_module(prior.get("root_module", {}), spec)
    prior.pop("outputs", None)

    planned = p.get("planned_values", {})
    filter_module(planned.get("root_module", {}), spec)
    planned.pop("outputs", None)

    p["resource_changes"] = [r for r in p.get("resource_changes", []) if matches(r, spec)]

    config = p.get("configuration", {}).get("root_module", {})
    if config:
        config["resources"] = [r for r in config.get("resources", []) if matches(r, spec)]
        config.pop("module_calls", None)
        config.pop("outputs", None)

    return p


def main() -> int:
    if len(sys.argv) < 2:
        print("Gebruik: python3 scripts/rover_layers.py plan.json", file=sys.stderr)
        return 1

    plan = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    OUT.mkdir(exist_ok=True)

    for name, spec in LAYERS.items():
        filtered = split(plan, spec)
        path = OUT / f"{name}.json"
        path.write_text(json.dumps(filtered), encoding="utf-8")
        count = len(filtered.get("resource_changes", []))
        print(f"{name:15} {count:3} resources -> {path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
