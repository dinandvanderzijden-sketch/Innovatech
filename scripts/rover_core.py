#!/usr/bin/env python3
"""Filtert een Terraform plan-JSON tot de kern van de omgeving voor Rover.

Rover tekent anders alle 170+ resources, inclusief IAM, route tables en
bucket-configuraties. Dit script houdt alleen de onderdelen over die de
omgeving als geheel laten zien.
"""

from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

# Resource-types die in het overzichtsdiagram horen.
CORE = [
    "aws_vpc",
    "aws_ec2_transit_gateway",
    "aws_ec2_transit_gateway_vpc_attachment",
    "aws_nat_gateway",
    "aws_internet_gateway",
    "aws_security_group",
    "aws_iam_role",
    "aws_lb",
    "aws_lb_target_group",
    "aws_lb_listener",
    "aws_instance",
    "aws_ecs_cluster",
    "aws_ecs_service",
    "aws_ecs_task_definition",
    "aws_ecr_repository",
    "aws_rds_cluster",
    "aws_rds_cluster_instance",
    "aws_db_subnet_group",
    "aws_s3_bucket",
    "aws_sqs_queue",
    "aws_cloudwatch_event_rule",
    "aws_lambda_function",
    "aws_api_gateway_rest_api",
    "aws_dynamodb_table",
    "aws_sns_topic",
    "aws_route53_zone",
    "aws_route53_record",
    "aws_secretsmanager_secret",
    "aws_db_subnet_group",
]


def keep(resource: dict) -> bool:
    return resource.get("type") in CORE


def filter_module(module: dict) -> None:
    if not module:
        return
    module["resources"] = [r for r in module.get("resources", []) if keep(r)]
    for child in module.get("child_modules", []) or []:
        filter_module(child)


def main() -> int:
    if len(sys.argv) < 2:
        print("Gebruik: python3 scripts/rover_core.py plan.json", file=sys.stderr)
        return 1

    plan = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    p = copy.deepcopy(plan)

    filter_module(p.get("prior_state", {}).get("values", {}).get("root_module", {}))
    p.get("prior_state", {}).get("values", {}).pop("outputs", None)

    filter_module(p.get("planned_values", {}).get("root_module", {}))
    p.get("planned_values", {}).pop("outputs", None)

    p["resource_changes"] = [r for r in p.get("resource_changes", []) if keep(r)]

    config = p.get("configuration", {}).get("root_module", {})
    if config:
        config["resources"] = [r for r in config.get("resources", []) if keep(r)]
        config.pop("module_calls", None)

    out = Path("plan-core.json")
    out.write_text(json.dumps(p), encoding="utf-8")
    print(f"{len(p['resource_changes'])} kernresources -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
