"""Alle instellingen op één plek, gelezen uit omgevingsvariabelen."""

import os


def _int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


REGION = os.environ.get("AWS_REGION", "eu-central-1")
QUEUE_URL = os.environ["QUEUE_URL"]
DEDUPE_TABLE = os.environ["DEDUPE_TABLE"]
AUDIT_BUCKET = os.environ["AUDIT_BUCKET"]
QUARANTINE_PREFIX = os.environ.get("QUARANTINE_PREFIX", "quarantine")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")
FIREWALL_FUNCTION_NAME = os.environ.get("FIREWALL_FUNCTION_NAME", "")
DB_HOST = os.environ.get("DB_HOST", "")
DB_PORT = _int("DB_PORT", 5432)
DB_NAME = os.environ.get("DB_NAME", "soar")
DB_USER = os.environ.get("DB_USER", "")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "CS2/SOAR")
SERVICE_NAME = os.environ.get("SERVICE_NAME", "cs2-dev-soar")
RULES_PATH = os.environ.get("RULES_PATH", "/app/rules.json")
MAX_MESSAGES = _int("MAX_MESSAGES", 10)
WAIT_SECONDS = _int("WAIT_SECONDS", 20)
