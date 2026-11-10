"""Alle bijwerkingen: firewall, quarantaine, melding en audit."""

from __future__ import annotations

import json
import logging
import threading
from dataclasses import asdict
from datetime import datetime, timezone
from typing import Any

import boto3

from . import config
from .engine import Finding

logger = logging.getLogger(__name__)

s3 = boto3.client("s3", region_name=config.REGION)
sns = boto3.client("sns", region_name=config.REGION)
ec2 = boto3.client("ec2", region_name=config.REGION)
lambda_client = boto3.client("lambda", region_name=config.REGION)
_db = None
_db_lock = threading.Lock()

SCHEMA = """
CREATE TABLE IF NOT EXISTS audit_events (
    id BIGSERIAL PRIMARY KEY,
    correlation_id TEXT NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source TEXT, detail_type TEXT, title TEXT, severity TEXT,
    source_ip TEXT, resource TEXT, rules JSONB, actions JSONB, payload JSONB
);
CREATE INDEX IF NOT EXISTS audit_events_occurred_at_idx ON audit_events (occurred_at DESC);
"""

INSERT_SQL = """
INSERT INTO audit_events
    (correlation_id, source, detail_type, title, severity,
     source_ip, resource, rules, actions, payload)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
"""


def run(actions: list[str], finding: Finding, rule: dict[str, Any] | None) -> list[dict[str, Any]]:
    """Voert acties na elkaar uit; één fout stopt de andere niet."""

    results: list[dict[str, Any]] = []
    for action in actions:
        try:
            if action == "block_ip":
                results.append(block_ip(finding))
            elif action == "quarantine":
                results.append(quarantine(finding))
            elif action == "notify":
                results.append(notify(finding, rule, list(results)))
            else:
                results.append({"action": action, "status": "overgeslagen"})
        except Exception as exc:
            logger.exception("Actie %s mislukt", action)
            results.append({"action": action, "status": "fout", "detail": str(exc)})
    return results


def block_ip(finding: Finding) -> dict[str, Any]:
    if not finding.source_ip:
        raise ValueError("Geen bron-IP bekend; blokkeren overgeslagen.")

    response = lambda_client.invoke(
        FunctionName=config.FIREWALL_FUNCTION_NAME,
        Payload=json.dumps(
            {
                "ip": finding.source_ip,
                "reason": f"{finding.title} ({finding.source})",
                "source": config.SERVICE_NAME,
                "ttl_seconds": 3600,
            }
        ).encode("utf-8"),
    )
    payload = json.loads(response["Payload"].read().decode("utf-8") or "{}")
    body = json.loads(payload.get("body", "{}"))
    if response.get("FunctionError") or payload.get("statusCode", 500) >= 400:
        raise RuntimeError(f"Firewall-Lambda faalde: {body.get('error', payload)}")

    return {"action": "block_ip", "status": "ok", "ip": finding.source_ip, "expires_at": body.get("expires_at")}


def quarantine(finding: Finding) -> dict[str, Any]:
    key = f"{config.QUARANTINE_PREFIX}/{finding.correlation_id()}.json"
    _put(
        key,
        {
            "quarantined_at": datetime.now(timezone.utc).isoformat(),
            "finding": asdict(finding),
            "note": "Host gemarkeerd voor isolatie; een analist controleert de isolate.",
        },
    )

    tagged = False
    if (finding.resource or "").startswith("i-"):
        try:
            ec2.create_tags(
                Resources=[finding.resource],
                Tags=[
                    {"Key": "Quarantine", "Value": "true"},
                    {"Key": "QuarantineReason", "Value": finding.title[:250]},
                ],
            )
            tagged = True
        except Exception as exc:  # pragma: no cover - afhankelijk van AWS
            logger.warning("Kon instance %s niet taggen: %s", finding.resource, exc)

    return {"action": "quarantine", "status": "ok", "evidence_object": key, "instance_tagged": tagged}


def notify(
    finding: Finding, rule: dict[str, Any] | None, results: list[dict[str, Any]]
) -> dict[str, Any]:
    if not config.SNS_TOPIC_ARN:
        raise ValueError("Geen SNS-topic geconfigureerd.")

    response = sns.publish(
        TopicArn=config.SNS_TOPIC_ARN,
        Subject=f"[CS2 {finding.severity.upper()}] {finding.title}"[:100],
        Message=json.dumps(
            {
                "service": config.SERVICE_NAME,
                "severity": finding.severity,
                "title": finding.title,
                "description": finding.description,
                "source": finding.source,
                "source_ip": finding.source_ip,
                "resource": finding.resource,
                "rules": [rule["id"]] if rule else [],
                "actions": results,
                "correlation_id": finding.correlation_id(),
            },
            indent=2,
            default=str,
        ),
    )
    return {"action": "notify", "status": "ok", "message_id": response.get("MessageId")}


def audit(
    finding: Finding, rule: dict[str, Any] | None, actions: list[dict[str, Any]]
) -> dict[str, str]:
    now = datetime.now(timezone.utc)
    correlation_id = finding.correlation_id()
    rule_ids = [rule["id"]] if rule else []
    key = f"events/dt={now:%Y-%m-%d}/{now:%H%M%S}-{correlation_id}.json"
    _put(
        key,
        {
            "correlation_id": correlation_id,
            "occurred_at": now.isoformat(),
            "finding": asdict(finding),
            "rules": rule_ids,
            "actions": actions,
        },
    )
    return {"s3_key": key, "db_written": str(_write_db(finding, correlation_id, rule_ids, actions))}


def recent(limit: int = 10) -> list[dict[str, Any]]:
    """Laatste auditregels uit Aurora, voor de demo en de dashboards."""

    rows = _execute(
        """SELECT occurred_at, severity, title, source, source_ip, rules, actions
           FROM audit_events ORDER BY id DESC LIMIT %s""",
        (max(1, min(limit, 100)),),
    )
    return [] if rows is None else [
        {key: value.isoformat() if hasattr(value, "isoformat") else value for key, value in row.items()}
        for row in rows
    ]


def _put(key: str, data: dict[str, Any]) -> None:
    s3.put_object(
        Bucket=config.AUDIT_BUCKET,
        Key=key,
        Body=json.dumps(data, default=str).encode("utf-8"),
        ContentType="application/json",
    )


# ------------------------------------------------------------------ database
def _execute(sql: str, params: tuple = ()) -> list[dict[str, Any]] | None:
    """Voert SQL uit. None betekent: geen database of een fout."""

    global _db
    with _db_lock:
        conn = _connection()
        if conn is None:
            return None
        try:
            import psycopg2.extras

            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                cur.execute(sql, params)
                return cur.fetchall() if cur.description else []
        except Exception as exc:
            logger.warning("Aurora-query mislukt: %s", exc)
            try:
                conn.close()
            except Exception:
                pass
            _db = None
            return None


def _connection():
    global _db
    if _db is not None and not _db.closed:
        return _db
    if not config.DB_HOST or not config.DB_USER:
        return None

    try:
        import psycopg2

        _db = psycopg2.connect(
            host=config.DB_HOST,
            port=config.DB_PORT,
            dbname=config.DB_NAME,
            user=config.DB_USER,
            password=config.DB_PASSWORD,
            connect_timeout=15,
        )
        _db.autocommit = True
        with _db.cursor() as cur:
            cur.execute(SCHEMA)
    except Exception as exc:
        logger.warning("Aurora niet bereikbaar, audit gaat alleen naar S3: %s", exc)
        _db = None
    return _db


def _write_db(
    finding: Finding,
    correlation_id: str,
    rule_ids: list[str],
    actions: list[dict[str, Any]],
) -> bool:
    return _execute(
        INSERT_SQL,
        (
            correlation_id,
            finding.source,
            finding.detail_type,
            finding.title,
            finding.severity,
            finding.source_ip,
            finding.resource,
            json.dumps(rule_ids),
            json.dumps(actions, default=str),
            json.dumps(asdict(finding), default=str),
        ),
    ) is not None
