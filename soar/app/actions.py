"""Uitvoering van SOAR-acties."""

from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Any

import boto3

from .config import Settings
from .models import Finding
from .rules import Rule

logger = logging.getLogger(__name__)


class ActionExecutor:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.s3 = boto3.client("s3", region_name=settings.region)
        self.sns = boto3.client("sns", region_name=settings.region)
        self.ec2 = boto3.client("ec2", region_name=settings.region)

    # ------------------------------------------------------------ block_ip
    def block_ip(self, finding: Finding) -> dict[str, Any]:
        if not finding.source_ip:
            raise ValueError("Geen bron-IP bekend; blokkeren overgeslagen.")

        payload = json.dumps(
            {
                "ip": finding.source_ip,
                "reason": f"{finding.title} ({finding.source})",
                "source": self.settings.service_name,
                "ttl_seconds": 3600,
            }
        ).encode("utf-8")

        request = urllib.request.Request(
            self.settings.firewall_api_url,
            data=payload,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "x-api-key": self.settings.firewall_api_key,
            },
        )

        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                body = json.loads(response.read().decode("utf-8") or "{}")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Firewall-API gaf HTTP {exc.code}: {detail}") from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(f"Firewall-API niet bereikbaar: {exc.reason}") from exc

        return {
            "action": "block_ip",
            "status": "ok",
            "ip": finding.source_ip,
            "expires_at": body.get("expires_at"),
        }

    # ------------------------------------------------------------ quarantine
    def quarantine(self, finding: Finding) -> dict[str, Any]:
        evidence = {
            "quarantined_at": datetime.now(timezone.utc).isoformat(),
            "finding": finding.model_dump(),
            "note": (
                "Host gemarkeerd voor isolatie. De daadwerkelijke netwerkisolatie "
                "gebeurt na controle door een analist."
            ),
        }

        key = f"{self.settings.quarantine_prefix}/{finding.correlation_id()}.json"
        self.s3.put_object(
            Bucket=self.settings.audit_bucket,
            Key=key,
            Body=json.dumps(evidence, default=str).encode("utf-8"),
            ContentType="application/json",
        )

        tagged = False
        resource = finding.resource or ""
        if resource.startswith("i-"):
            try:
                self.ec2.create_tags(
                    Resources=[resource],
                    Tags=[
                        {"Key": "Quarantine", "Value": "true"},
                        {"Key": "QuarantineReason", "Value": finding.title[:250]},
                    ],
                )
                tagged = True
            except Exception as exc:  # pragma: no cover - afhankelijk van AWS
                logger.warning("Kon instance %s niet taggen: %s", resource, exc)

        return {
            "action": "quarantine",
            "status": "ok",
            "evidence_object": key,
            "instance_tagged": tagged,
        }

    # ------------------------------------------------------------ notify
    def notify(self, finding: Finding, rules: list[Rule], results: list[dict[str, Any]]) -> dict[str, Any]:
        if not self.settings.sns_topic_arn:
            raise ValueError("Geen SNS-topic geconfigureerd.")

        message = {
            "service": self.settings.service_name,
            "severity": finding.severity,
            "title": finding.title,
            "description": finding.description,
            "source": finding.source,
            "source_ip": finding.source_ip,
            "resource": finding.resource,
            "rules": [rule.id for rule in rules],
            "actions": results,
            "correlation_id": finding.correlation_id(),
        }

        response = self.sns.publish(
            TopicArn=self.settings.sns_topic_arn,
            Subject=f"[CS2 {finding.severity.upper()}] {finding.title}"[:100],
            Message=json.dumps(message, indent=2, default=str),
        )

        return {
            "action": "notify",
            "status": "ok",
            "message_id": response.get("MessageId"),
        }

    # ------------------------------------------------------------ orchestration
    def execute(self, actions: list[str], finding: Finding, rules: list[Rule]) -> list[dict[str, Any]]:
        results: list[dict[str, Any]] = []

        for action in actions:
            try:
                if action == "block_ip":
                    results.append(self.block_ip(finding))
                elif action == "quarantine":
                    results.append(self.quarantine(finding))
                elif action == "notify":
                    # Notificaties gaan als laatste, zodat ze de uitgevoerde acties bevatten.
                    results.append(self.notify(finding, rules, list(results)))
                else:
                    results.append({"action": action, "status": "overgeslagen"})
            except Exception as exc:
                logger.exception("Actie %s mislukt", action)
                results.append({"action": action, "status": "fout", "detail": str(exc)})

        return results
