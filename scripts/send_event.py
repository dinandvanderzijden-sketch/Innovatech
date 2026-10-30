#!/usr/bin/env python3
"""Stuurt een demo-gebeurtenis naar EventBridge.

Twee modi:
  alarm    -- doet zich voor als een CloudWatch-alarm (de normale flow)
  finding  -- stuurt een eigen beveiligingsbevinding (brute force, scan, ...)

Voorbeelden:
  ./scripts/send_event.py --mode alarm --alarm-name cs2-dev-cpu-0
  ./scripts/send_event.py --mode finding --title "SSH brute force" \
      --severity high --ip 203.0.113.7
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import uuid

import boto3


def build_alarm(args: argparse.Namespace) -> dict:
    metric = {
        "namespace": "AWS/EC2",
        "name": args.metric,
        "dimensions": {},
    }
    if args.resource:
        metric["dimensions"]["InstanceId"] = args.resource

    return {
        "source": "aws.cloudwatch",
        "detail-type": "CloudWatch Alarm State Change",
        "detail": {
            "alarmName": args.alarm_name,
            "alarmDescription": args.description or "Demo-alarm via send_event.py",
            "state": {"value": "ALARM", "reason": "Demo-gebeurtenis"},
            "configuration": {"metrics": [{"metricStat": {"metric": metric}}]},
            "region": args.region,
            "accountId": args.account,
        },
    }


def build_finding(args: argparse.Namespace) -> dict:
    return {
        "source": "cs2.demo",
        "detail-type": "CS2 Security Finding",
        "detail": {
            "id": str(uuid.uuid4()),
            "source": "cs2.demo",
            "title": args.title,
            "description": args.description or "Handmatig gestarte demo-bevinding",
            "severity": args.severity,
            "source_ip": args.ip,
            "resource": args.resource,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Stuur een demo-event naar EventBridge.")
    parser.add_argument("--mode", choices=["alarm", "finding"], default="alarm")
    parser.add_argument("--region", default=os.environ.get("AWS_REGION", "eu-central-1"))
    parser.add_argument("--account", default="", help="AWS-account-ID (optioneel)")
    parser.add_argument("--alarm-name", default="cs2-dev-demo-cpu")
    parser.add_argument("--metric", default="CPUUtilization")
    parser.add_argument("--title", default="SSH brute force gedetecteerd")
    parser.add_argument("--description", default="")
    parser.add_argument("--severity", default="high", choices=["low", "medium", "high", "critical"])
    parser.add_argument("--ip", default=None, help="Bron-IP voor de bevinding")
    parser.add_argument("--resource", default=None, help="Instance-ID of andere resource")
    args = parser.parse_args()

    if not args.account:
        args.account = boto3.client("sts", region_name=args.region).get_caller_identity()["Account"]

    event = build_alarm(args) if args.mode == "alarm" else build_finding(args)

    client = boto3.client("events", region_name=args.region)
    response = client.put_events(
        Entries=[
            {
                "Source": event["source"],
                "DetailType": event["detail-type"],
                "Detail": json.dumps(event["detail"]),
                "EventBusName": "default",
            }
        ]
    )

    failed = response.get("FailedEntryCount", 0)
    print(json.dumps(response, indent=2, default=str))

    if failed:
        print("EventBridge kon het event niet aannemen.", file=sys.stderr)
        return 1

    print("Event geaccepteerd. De SOAR verwerkt het binnen enkele seconden.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
