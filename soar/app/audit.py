"""Auditlogging naar S3 en Aurora Serverless v2."""

from __future__ import annotations

import json
import logging
import threading
from datetime import datetime, timezone
from typing import Any

import boto3

from .config import Settings
from .models import Finding

logger = logging.getLogger(__name__)

SCHEMA = """
CREATE TABLE IF NOT EXISTS audit_events (
    id           BIGSERIAL PRIMARY KEY,
    correlation_id TEXT NOT NULL,
    occurred_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    source       TEXT,
    detail_type  TEXT,
    title        TEXT,
    severity     TEXT,
    source_ip    TEXT,
    resource     TEXT,
    rules        JSONB,
    actions      JSONB,
    payload      JSONB
);
CREATE INDEX IF NOT EXISTS audit_events_occurred_at_idx ON audit_events (occurred_at DESC);
"""


class AuditStore:
    """Schrijft elk verwerkt event naar S3 en (indien bereikbaar) naar Aurora."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.s3 = boto3.client("s3", region_name=settings.region)
        self._lock = threading.Lock()
        self._conn = None
        self._db_ready = False

    # ------------------------------------------------------------ database
    def _connect(self):
        if not self.settings.db_host or not self.settings.db_user:
            return None

        import psycopg2

        conn = psycopg2.connect(
            host=self.settings.db_host,
            port=self.settings.db_port,
            dbname=self.settings.db_name,
            user=self.settings.db_user,
            password=self.settings.db_password,
            connect_timeout=15,
        )
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute(SCHEMA)
        return conn

    def _ensure_db(self):
        if self._db_ready and self._conn is not None and not self._conn.closed:
            return self._conn

        try:
            self._conn = self._connect()
            self._db_ready = self._conn is not None
        except Exception as exc:
            logger.warning("Aurora niet bereikbaar, audit gaat alleen naar S3: %s", exc)
            self._conn = None
            self._db_ready = False

        return self._conn

    # ------------------------------------------------------------ public
    def record(
        self,
        finding: Finding,
        rules: list[str],
        actions: list[dict[str, Any]],
    ) -> dict[str, str]:
        now = datetime.now(timezone.utc)
        correlation_id = finding.correlation_id()
        payload = {
            "correlation_id": correlation_id,
            "occurred_at": now.isoformat(),
            "finding": finding.model_dump(),
            "rules": rules,
            "actions": actions,
        }

        key = f"events/dt={now:%Y-%m-%d}/{now:%H%M%S}-{correlation_id}.json"
        self.s3.put_object(
            Bucket=self.settings.audit_bucket,
            Key=key,
            Body=json.dumps(payload, default=str).encode("utf-8"),
            ContentType="application/json",
        )

        db_written = False
        with self._lock:
            conn = self._ensure_db()
            if conn is not None:
                try:
                    import psycopg2.extras

                    with conn.cursor() as cur:
                        cur.execute(
                            """
                            INSERT INTO audit_events
                                (correlation_id, source, detail_type, title, severity,
                                 source_ip, resource, rules, actions, payload)
                            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                            """,
                            (
                                correlation_id,
                                finding.source,
                                finding.detail_type,
                                finding.title,
                                finding.severity,
                                finding.source_ip,
                                finding.resource,
                                json.dumps(rules),
                                json.dumps(actions, default=str),
                                json.dumps(finding.model_dump(), default=str),
                            ),
                        )
                    db_written = True
                except Exception as exc:
                    logger.warning("Schrijven naar Aurora mislukt: %s", exc)
                    self._db_ready = False
                    try:
                        conn.close()
                    except Exception:
                        pass
                    self._conn = None

        return {"s3_key": key, "db_written": str(db_written)}

    def recent(self, limit: int = 10) -> list[dict[str, Any]]:
        """Laatste auditregels uit Aurora, voor de demo en voor dashboards."""

        limit = max(1, min(limit, 100))

        with self._lock:
            conn = self._ensure_db()
            if conn is None:
                return []

            try:
                import psycopg2.extras

                with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                    cur.execute(
                        """
                        SELECT occurred_at, severity, title, source, source_ip, rules, actions
                        FROM audit_events
                        ORDER BY id DESC
                        LIMIT %s
                        """,
                        (limit,),
                    )
                    rows = cur.fetchall()
            except Exception as exc:
                logger.warning("Lezen uit Aurora mislukt: %s", exc)
                self._db_ready = False
                try:
                    conn.close()
                except Exception:
                    pass
                self._conn = None
                return []

        return [
            {
                key: (value.isoformat() if hasattr(value, "isoformat") else value)
                for key, value in row.items()
            }
            for row in rows
        ]
