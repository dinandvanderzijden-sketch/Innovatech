"""FastAPI-applicatie voor de SOAR.

De applicatie doet twee dingen:
1. Ze neemt events aan via HTTP (POST /events) en zet ze op de SQS-queue.
2. Een achtergrondthread leest de queue, past de regels toe, voert acties uit
   en schrijft het resultaat naar de auditopslag.
"""

from __future__ import annotations

import json
import logging
import threading
import time
from contextlib import asynccontextmanager
from typing import Any

import boto3
from botocore.exceptions import ClientError
from fastapi import Body, FastAPI, HTTPException
from fastapi.responses import JSONResponse

from .actions import ActionExecutor
from .audit import AuditStore
from .config import Settings, load_settings
from .models import Finding, normalize_event
from .rules import RuleSet, planned_actions

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("soar")

DEDUPE_TTL_SECONDS = 15 * 60
DEDUPE_WINDOW_SECONDS = 5 * 60


class SoarService:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.sqs = boto3.client("sqs", region_name=settings.region)
        self.dynamodb = boto3.resource("dynamodb", region_name=settings.region)
        self.cloudwatch = boto3.client("cloudwatch", region_name=settings.region)
        self.dedupe_table = self.dynamodb.Table(settings.dedupe_table)

        self.rules = RuleSet.load(settings.rules_path)
        self.audit = AuditStore(settings)
        self.executor = ActionExecutor(settings)

        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._stats_lock = threading.Lock()
        self.stats = {
            "received": 0,
            "processed": 0,
            "duplicates": 0,
            "matched": 0,
            "errors": 0,
        }

    # ------------------------------------------------------------ metrics
    def _metric(self, name: str, value: float = 1) -> None:
        try:
            self.cloudwatch.put_metric_data(
                Namespace=self.settings.metric_namespace,
                MetricData=[
                    {
                        "MetricName": name,
                        "Value": value,
                        "Unit": "Count",
                        "Dimensions": [
                            {"Name": "ServiceName", "Value": self.settings.service_name}
                        ],
                    }
                ],
            )
        except Exception as exc:  # noqa: BLE001 - metriek mag nooit het proces stoppen
            logger.warning("CloudWatch-metriek %s mislukt: %s", name, exc)

    def _count(self, key: str) -> None:
        with self._stats_lock:
            self.stats[key] += 1

    # ------------------------------------------------------------ dedupe
    def _is_new(self, correlation_id: str) -> bool:
        # Binnen vijf minuten telt hetzelfde event als duplicaat. Daarna mag
        # het opnieuw verwerkt worden (bijvoorbeeld een aanhoudend alarm).
        window = int(time.time() // DEDUPE_WINDOW_SECONDS)
        dedupe_id = f"{correlation_id}#{window}"

        try:
            self.dedupe_table.put_item(
                Item={
                    "correlation_id": dedupe_id,
                    "expires_at": int(time.time()) + DEDUPE_TTL_SECONDS,
                },
                ConditionExpression="attribute_not_exists(correlation_id)",
            )
            return True
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return False
            raise

    # ------------------------------------------------------------ worker
    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, name="soar-worker", daemon=True)
        self._thread.start()
        logger.info(
            "SOAR-worker gestart (queue=%s, regels=%d)",
            self.settings.queue_url,
            len(self.rules.rules),
        )

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=25)

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                response = self.sqs.receive_message(
                    QueueUrl=self.settings.queue_url,
                    MaxNumberOfMessages=self.settings.max_messages,
                    WaitTimeSeconds=self.settings.wait_seconds,
                    VisibilityTimeout=120,
                    AttributeNames=["ApproximateReceiveCount"],
                )
            except Exception as exc:  # noqa: BLE001
                logger.error("Lezen uit SQS mislukt: %s", exc)
                self._stop.wait(5)
                continue

            for message in response.get("Messages", []):
                if self._stop.is_set():
                    break
                self._handle(message)

    def _handle(self, message: dict[str, Any]) -> None:
        self._count("received")
        receipt = message.get("ReceiptHandle", "")

        try:
            body = json.loads(message.get("Body", "{}"))
            finding = normalize_event(body)
            correlation_id = finding.correlation_id()

            if not self._is_new(correlation_id):
                self._count("duplicates")
                logger.info("Duplicaat overgeslagen: %s", correlation_id)
                self.sqs.delete_message(
                    QueueUrl=self.settings.queue_url, ReceiptHandle=receipt
                )
                return

            matched = self.rules.select(finding)
            actions = planned_actions(matched)

            if matched:
                self._count("matched")
                logger.info(
                    "Event %s: %s (ernst=%s, regel=%s, acties=%s)",
                    correlation_id,
                    finding.title,
                    finding.severity,
                    matched[0].id,
                    actions,
                )
            else:
                logger.info(
                    "Event %s: %s (ernst=%s) heeft geen regel; alleen audit.",
                    correlation_id,
                    finding.title,
                    finding.severity,
                )

            results = self.executor.execute(actions, finding, matched)
            audit_info = self.audit.record(
                finding, [rule.id for rule in matched], results
            )

            self._count("processed")
            self._metric("EventsProcessed")
            successes = sum(1 for r in results if r.get("status") == "ok")
            if successes:
                self._metric("ActionsExecuted", successes)
            if any(r.get("status") == "fout" for r in results):
                self._metric("ProcessingErrors")

            logger.info("Audit opgeslagen: %s", audit_info)

            self.sqs.delete_message(
                QueueUrl=self.settings.queue_url, ReceiptHandle=receipt
            )

        except Exception:  # noqa: BLE001
            self._count("errors")
            self._metric("ProcessingErrors")
            logger.exception(
                "Verwerken mislukt; bericht blijft op de queue en gaat na 3 pogingen naar de DLQ."
            )

            # Oplopende wachttijd: 30s, 60s, 120s, ... maximaal 15 minuten.
            try:
                attempt = int(message.get("Attributes", {}).get("ApproximateReceiveCount", "1"))
                delay = min(30 * (2 ** (attempt - 1)), 900)
                self.sqs.change_message_visibility(
                    QueueUrl=self.settings.queue_url,
                    ReceiptHandle=receipt,
                    VisibilityTimeout=delay,
                )
            except Exception:  # noqa: BLE001
                logger.warning("Kon de visibility-timeout niet aanpassen.")


settings = load_settings()
service = SoarService(settings)


@asynccontextmanager
async def lifespan(app: FastAPI):
    service.start()
    yield
    service.stop()


app = FastAPI(
    title="CS2 SOAR",
    description="Security Orchestration, Automation and Response voor de CS2-omgeving.",
    version="1.0.0",
    lifespan=lifespan,
)


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "service": settings.service_name,
        "rules": len(service.rules.rules),
        "queue": settings.queue_url.rsplit("/", 1)[-1],
        "worker_alive": bool(service._thread and service._thread.is_alive()),
    }


@app.get("/stats")
def stats() -> dict[str, Any]:
    with service._stats_lock:
        return dict(service.stats)


@app.get("/rules")
def rules() -> dict[str, Any]:
    return {
        "count": len(service.rules.rules),
        "rules": [rule.as_dict() for rule in service.rules.rules],
    }


@app.get("/audit/recent")
def recent_audit(limit: int = 10) -> dict[str, Any]:
    items = service.audit.recent(limit)
    return {"count": len(items), "items": items}


@app.post("/events", status_code=202)
def ingest(payload: dict[str, Any] = Body(...)) -> JSONResponse:
    """Zet een event op de queue. Handig voor de demo en voor externe bronnen."""

    if "detail-type" not in payload:
        try:
            Finding.model_validate(payload)
        except Exception as exc:  # noqa: BLE001
            raise HTTPException(status_code=422, detail=f"Ongeldige bevinding: {exc}") from exc

    try:
        response = service.sqs.send_message(
            QueueUrl=settings.queue_url,
            MessageBody=json.dumps(payload, default=str),
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("Naar SQS sturen mislukt")
        raise HTTPException(status_code=503, detail="Queue niet beschikbaar") from exc

    return JSONResponse(
        status_code=202,
        content={"status": "queued", "message_id": response.get("MessageId")},
    )
