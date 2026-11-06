#!/usr/bin/env python3
"""Stuurt een demo-gebeurtenis naar EventBridge.

Gebruikt de AWS CLI, zodat er geen Python-pakketten nodig zijn. De CLI is al
nodig voor de andere scripts.

Twee modi:
  alarm    -- doet zich voor als een CloudWatch-alarm (de normale flow)
  finding  -- stuurt een eigen beveiligingsbevinding (brute force, scan, ...)

Voorbeelden:
  ./scripts/send_event.py --mode alarm --alarm-name cs2-dev-cpu-0
  ./scripts/send_event.py --mode finding --title "SSH brute force" \\
      --severity high --ip 203.0.113.7
  ./scripts/send_event.py --mode finding --ip 203.0.113.7 --dry-run
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import uuid


def aws(args: list[str], region: str) -> str:
    """Voert een AWS CLI-commando uit en geeft de stdout terug."""
    result = subprocess.run(
        ["aws", *args, "--region", region],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(result.stderr.strip() or "AWS CLI-commando mislukt.", file=sys.stderr)
        raise SystemExit(result.returncode)
    return result.stdout.strip()


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
    parser.add_argument("--dry-run", action="store_true", help="Alleen tonen, niet versturen")
    args = parser.parse_args()

    if not args.account:
        args.account = (
            "123456789012"
            if args.dry_run
            else aws(["sts", "get-caller-identity", "--query", "Account", "--output", "text"], args.region)
        )

    event = build_alarm(args) if args.mode == "alarm" else build_finding(args)
    entries = [
        {
            "Source": event["source"],
            "DetailType": event["detail-type"],
            "Detail": json.dumps(event["detail"]),
            "EventBusName": "default",
        }
    ]

    if args.dry_run:
        print(json.dumps(entries, indent=2, ensure_ascii=False))
        return 0

    response = aws(["events", "put-events", "--entries", json.dumps(entries)], args.region)
    try:
        parsed = json.loads(response)
    except json.JSONDecodeError:
        print(response)
        return 0

    print(json.dumps(parsed, indent=2, ensure_ascii=False))

    if parsed.get("FailedEntryCount", 0):
        print("EventBridge kon het event niet aannemen.", file=sys.stderr)
        return 1

    print("Event geaccepteerd. De SOAR verwerkt het binnen enkele seconden.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
