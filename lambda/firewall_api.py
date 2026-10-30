"""Gesimuleerde firewall-API.

De SOAR roept deze Lambda aan om een IP te blokkeren. In een echte omgeving
zou dit AWS Network Firewall, een WAF of een firewall-appliance aansturen.
Hier wordt de blokkade in DynamoDB vastgelegd, zodat de demo laat zien dat de
SOAR daadwerkelijk een actie uitvoert.
"""

import ipaddress
import json
import os
import time
from datetime import datetime, timezone

import boto3

TABLE_NAME = os.environ["TABLE_NAME"]
DEFAULT_TTL = 3600
MAX_TTL = 86400

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)


def _response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _parse_body(event: dict) -> dict:
    raw = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        import base64

        raw = base64.b64decode(raw).decode("utf-8")
    return json.loads(raw)


def handler(event, context):
    try:
        payload = _parse_body(event)
    except (ValueError, TypeError):
        return _response(400, {"error": "Ongeldige JSON in de request-body."})

    raw_ip = str(payload.get("ip", "")).strip()
    try:
        ip = ipaddress.ip_address(raw_ip)
    except ValueError:
        return _response(422, {"error": f"'{raw_ip}' is geen geldig IP-adres."})

    ttl = payload.get("ttl_seconds", DEFAULT_TTL)
    try:
        ttl = int(ttl)
    except (TypeError, ValueError):
        ttl = DEFAULT_TTL
    ttl = max(60, min(ttl, MAX_TTL))

    now = int(time.time())
    item = {
        "ip": str(ip),
        "reason": str(payload.get("reason", "SOAR-automatisering"))[:500],
        "source": str(payload.get("source", "soar"))[:100],
        "blocked_at": datetime.now(timezone.utc).isoformat(),
        "expires_at": now + ttl,
        "ttl_seconds": ttl,
        "request_id": getattr(context, "aws_request_id", "onbekend"),
    }

    table.put_item(Item=item)

    return _response(
        201,
        {
            "status": "blocked",
            "ip": item["ip"],
            "expires_at": item["expires_at"],
            "reason": item["reason"],
        },
    )
