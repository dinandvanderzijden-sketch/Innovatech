"""Configuratie uit omgevingsvariabelen."""

import os
from dataclasses import dataclass


def _int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


@dataclass(frozen=True)
class Settings:
    region: str
    queue_url: str
    dlq_url: str
    dedupe_table: str
    audit_bucket: str
    quarantine_prefix: str
    sns_topic_arn: str
    firewall_api_url: str
    firewall_api_key: str
    db_host: str
    db_port: int
    db_name: str
    db_user: str
    db_password: str
    metric_namespace: str
    service_name: str
    rules_path: str
    max_messages: int = 10
    wait_seconds: int = 20


def load_settings() -> Settings:
    return Settings(
        region=os.environ.get("AWS_REGION", "eu-central-1"),
        queue_url=os.environ["QUEUE_URL"],
        dlq_url=os.environ.get("DLQ_URL", ""),
        dedupe_table=os.environ["DEDUPE_TABLE"],
        audit_bucket=os.environ["AUDIT_BUCKET"],
        quarantine_prefix=os.environ.get("QUARANTINE_PREFIX", "quarantine"),
        sns_topic_arn=os.environ.get("SNS_TOPIC_ARN", ""),
        firewall_api_url=os.environ.get("FIREWALL_API_URL", ""),
        firewall_api_key=os.environ.get("FIREWALL_API_KEY", ""),
        db_host=os.environ.get("DB_HOST", ""),
        db_port=_int("DB_PORT", 5432),
        db_name=os.environ.get("DB_NAME", "soar"),
        db_user=os.environ.get("DB_USER", ""),
        db_password=os.environ.get("DB_PASSWORD", ""),
        metric_namespace=os.environ.get("METRIC_NAMESPACE", "CS2/SOAR"),
        service_name=os.environ.get("SERVICE_NAME", "cs2-dev-soar"),
        rules_path=os.environ.get("RULES_PATH", "/app/rules.json"),
        max_messages=_int("MAX_MESSAGES", 10),
        wait_seconds=_int("WAIT_SECONDS", 20),
    )
