"""HTTP-API en SQS-worker. De kernflow staat in process()."""

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

from . import config, effects
from .engine import best_rule, load_rules, normalize_event, parse, planned_actions

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger("soar")

sqs = boto3.client("sqs", region_name=config.REGION)
cloudwatch = boto3.client("cloudwatch", region_name=config.REGION)
table = boto3.resource("dynamodb", region_name=config.REGION).Table(config.DEDUPE_TABLE)
rules = load_rules(config.RULES_PATH)
stats = {"received": 0, "processed": 0, "duplicates": 0, "matched": 0, "errors": 0}
stats_lock = threading.Lock()
stop = threading.Event()
thread: threading.Thread | None = None


def _count(key: str) -> None:
    with stats_lock:
        stats[key] += 1


def _metric(name: str, value: float = 1) -> None:
    try:
        cloudwatch.put_metric_data(
            Namespace=config.METRIC_NAMESPACE,
            MetricData=[{
                "MetricName": name,
                "Value": value,
                "Unit": "Count",
                "Dimensions": [{"Name": "ServiceName", "Value": config.SERVICE_NAME}],
            }],
        )
    except Exception as exc:  # noqa: BLE001 - metriek mag het proces niet stoppen
        logger.warning("CloudWatch-metriek %s mislukt: %s", name, exc)


def _is_new(correlation_id: str) -> bool:
    # Binnen vijf minuten telt hetzelfde event als duplicaat; daarna opnieuw.
    window = int(time.time() // (5 * 60))
    try:
        table.put_item(
            Item={
                "correlation_id": f"{correlation_id}#{window}",
                "expires_at": int(time.time()) + 15 * 60,
            },
            ConditionExpression="attribute_not_exists(correlation_id)",
        )
        return True
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def process(event: dict[str, Any]) -> dict[str, Any]:
    """De leesbare kern: event → bevinding → dedupe → regel → acties → audit."""

    _count("received")
    finding = normalize_event(event)
    correlation_id = finding.correlation_id()

    if not _is_new(correlation_id):
        _count("duplicates")
        logger.info("Duplicaat overgeslagen: %s", correlation_id)
        return {"status": "duplicate", "correlation_id": correlation_id}

    rule = best_rule(rules, finding)
    actions = planned_actions(rule)
    if rule:
        _count("matched")
        logger.info("Event %s: %s (ernst=%s, regel=%s, acties=%s)",
                    correlation_id, finding.title, finding.severity, rule["id"], actions)
    else:
        logger.info("Event %s: %s (ernst=%s) heeft geen regel; alleen audit.",
                    correlation_id, finding.title, finding.severity)

    results = effects.run(actions, finding, rule)
    audit_info = effects.audit(finding, rule, results)
    _count("processed")
    _metric("EventsProcessed")
    successes = sum(1 for result in results if result.get("status") == "ok")
    if successes:
        _metric("ActionsExecuted", successes)
    if any(result.get("status") == "fout" for result in results):
        _metric("ProcessingErrors")
    logger.info("Audit opgeslagen: %s", audit_info)

    return {
        "status": "processed",
        "correlation_id": correlation_id,
        "rule": rule["id"] if rule else None,
        "actions": results,
        "audit": audit_info,
    }


def _handle(message: dict[str, Any]) -> None:
    receipt = message.get("ReceiptHandle", "")
    try:
        process(json.loads(message.get("Body", "{}")))
        sqs.delete_message(QueueUrl=config.QUEUE_URL, ReceiptHandle=receipt)
    except Exception:  # noqa: BLE001
        _count("errors")
        _metric("ProcessingErrors")
        logger.exception("Verwerken mislukt; bericht blijft op de queue en gaat na 3 pogingen naar de DLQ.")
        try:
            attempt = int(message.get("Attributes", {}).get("ApproximateReceiveCount", "1"))
            sqs.change_message_visibility(
                QueueUrl=config.QUEUE_URL,
                ReceiptHandle=receipt,
                VisibilityTimeout=min(30 * (2 ** (attempt - 1)), 900),
            )
        except Exception:  # noqa: BLE001
            logger.warning("Kon de visibility-timeout niet aanpassen.")


def _worker() -> None:
    while not stop.is_set():
        try:
            response = sqs.receive_message(
                QueueUrl=config.QUEUE_URL,
                MaxNumberOfMessages=config.MAX_MESSAGES,
                WaitTimeSeconds=config.WAIT_SECONDS,
                VisibilityTimeout=120,
                AttributeNames=["ApproximateReceiveCount"],
            )
        except Exception as exc:  # noqa: BLE001
            logger.error("Lezen uit SQS mislukt: %s", exc)
            stop.wait(5)
            continue
        for message in response.get("Messages", []):
            if stop.is_set():
                break
            _handle(message)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global thread
    thread = threading.Thread(target=_worker, name="soar-worker", daemon=True)
    thread.start()
    logger.info("SOAR-worker gestart (queue=%s, regels=%d)", config.QUEUE_URL, len(rules))
    yield
    stop.set()
    thread.join(timeout=25)


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
        "service": config.SERVICE_NAME,
        "rules": len(rules),
        "queue": config.QUEUE_URL.rsplit("/", 1)[-1],
        "worker_alive": bool(thread and thread.is_alive()),
    }


@app.get("/stats")
def get_stats() -> dict[str, Any]:
    with stats_lock:
        return dict(stats)


@app.get("/rules")
def get_rules() -> dict[str, Any]:
    return {"count": len(rules), "rules": rules}


@app.get("/audit/recent")
def recent_audit(limit: int = 10) -> dict[str, Any]:
    items = effects.recent(limit)
    return {"count": len(items), "items": items}


@app.post("/events", status_code=202)
def ingest(payload: dict[str, Any] = Body(...)) -> JSONResponse:
    """Zet een event op de queue. Handig voor de demo en voor externe bronnen."""

    if "detail-type" not in payload and "detail_type" not in payload:
        try:
            parse(payload)
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=f"Ongeldige bevinding: {exc}") from exc

    try:
        response = sqs.send_message(QueueUrl=config.QUEUE_URL, MessageBody=json.dumps(payload, default=str))
    except Exception as exc:  # noqa: BLE001
        logger.exception("Naar SQS sturen mislukt")
        raise HTTPException(status_code=503, detail="Queue niet beschikbaar") from exc

    return JSONResponse(status_code=202, content={"status": "queued", "message_id": response.get("MessageId")})
