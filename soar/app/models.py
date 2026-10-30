"""Datamodellen en normalisatie van inkomende gebeurtenissen."""

from __future__ import annotations

import hashlib
import json
from typing import Any

from pydantic import BaseModel, Field

SEVERITY_ORDER = {"info": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}


class Finding(BaseModel):
    """Een genormaliseerde beveiligingsbevinding."""

    id: str = ""
    source: str = "onbekend"
    detail_type: str = "Onbekend"
    title: str
    description: str = ""
    severity: str = "medium"
    source_ip: str | None = None
    resource: str | None = None
    raw: dict[str, Any] = Field(default_factory=dict)

    def correlation_id(self) -> str:
        if self.id:
            return self.id
        basis = json.dumps(
            {
                "source": self.source,
                "detail_type": self.detail_type,
                "title": self.title,
                "source_ip": self.source_ip,
                "resource": self.resource,
            },
            sort_keys=True,
        )
        return hashlib.sha256(basis.encode("utf-8")).hexdigest()[:32]

    def severity_rank(self) -> int:
        return SEVERITY_ORDER.get(self.severity.lower(), 2)


def _alarm_severity(alarm_name: str) -> str:
    name = alarm_name.lower()
    if any(word in name for word in ("cpu", "5xx", "unhealthy", "disk", "memory")):
        return "high"
    if "test" in name:
        return "low"
    return "medium"


def _alarm_resource(detail: dict[str, Any]) -> str | None:
    try:
        return detail["configuration"]["metrics"][0]["metricStat"]["metric"]["dimensions"].get(
            "InstanceId"
        )
    except (KeyError, IndexError, TypeError):
        return None


def normalize_event(event: dict[str, Any]) -> Finding:
    """Zet een EventBridge- of SQS-bericht om naar een Finding."""

    detail_type = event.get("detail-type") or event.get("detail_type") or "Onbekend"
    detail = event.get("detail") or {}

    if detail_type == "CloudWatch Alarm State Change":
        alarm_name = detail.get("alarmName", "Onbekend alarm")
        return Finding(
            id=detail.get("alarmArn", ""),
            source="aws.cloudwatch",
            detail_type=detail_type,
            title=alarm_name,
            description=detail.get("alarmDescription", ""),
            severity=_alarm_severity(alarm_name),
            resource=_alarm_resource(detail),
            raw=event,
        )

    if detail_type == "CS2 Security Finding":
        return Finding(
            id=str(detail.get("id", "")),
            source=str(detail.get("source", "cs2.demo")),
            detail_type=detail_type,
            title=str(detail.get("title", "Beveiligingsbevinding")),
            description=str(detail.get("description", "")),
            severity=str(detail.get("severity", "medium")).lower(),
            source_ip=detail.get("source_ip"),
            resource=detail.get("resource"),
            raw=event,
        )

    # Bericht dat al direct als Finding is aangeleverd (bijvoorbeeld via POST /events).
    if "title" in event and "detail-type" not in event:
        return Finding.model_validate(event)

    return Finding(
        source=str(event.get("source", "onbekend")),
        detail_type=str(detail_type),
        title=str(event.get("title") or detail.get("title") or "Onbekende gebeurtenis"),
        description=str(event.get("description", "")),
        severity=str(event.get("severity", "medium")).lower(),
        raw=event,
    )
