"""Gesimuleerde firewall-API: legt een IP-blokkade in DynamoDB vast."""

import base64
import ipaddress
import json
import os
import time
from datetime import datetime, timezone

import boto3

table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
DEFAULT_TTL, MAX_TTL = 3600, 86400


def response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def payload_of(event: dict) -> dict:
    # Directe invoke vanuit de SOAR: het event is dan al de payload.
    if "body" not in event:
        return event
    raw = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    return json.loads(raw)


def handler(event, context):
    try:
        payload = payload_of(event)
    except (ValueError, TypeError):
        return response(400, {"error": "Ongeldige JSON in de request-body."})

    raw_ip = str(payload.get("ip", "")).strip()
    try:
        ip = ipaddress.ip_address(raw_ip)
    except ValueError:
        return response(422, {"error": f"'{raw_ip}' is geen geldig IP-adres."})

    try:
        ttl = int(payload.get("ttl_seconds", DEFAULT_TTL))
    except (TypeError, ValueError):
        ttl = DEFAULT_TTL
    ttl = max(60, min(ttl, MAX_TTL))

    item = {
        "ip": str(ip),
        "reason": str(payload.get("reason", "SOAR-automatisering"))[:500],
        "source": str(payload.get("source", "soar"))[:100],
        "blocked_at": datetime.now(timezone.utc).isoformat(),
        "expires_at": int(time.time()) + ttl,
        "ttl_seconds": ttl,
        "request_id": getattr(context, "aws_request_id", "onbekend"),
    }
    table.put_item(Item=item)
    return response(
        201,
        {
            "status": "blocked",
            "ip": item["ip"],
            "expires_at": item["expires_at"],
            "reason": item["reason"],
        },
    )
