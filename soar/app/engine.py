"""Pure spellogica: event → Finding → regel → acties. Geen AWS, geen I/O."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

SEVERITY = {"info": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}
ACTIONS = ("block_ip", "quarantine", "notify")


@dataclass
class Finding:
    """Eén genormaliseerde beveiligingsbevinding."""

    title: str
    id: str = ""
    source: str = "onbekend"
    detail_type: str = "Onbekend"
    description: str = ""
    severity: str = "medium"
    source_ip: str | None = None
    resource: str | None = None
    raw: dict[str, Any] = field(default_factory=dict)

    def correlation_id(self) -> str:
        """Stabiele id waarmee duplicaten en auditregels worden herkend."""

        if self.id:
            return self.id
        basis = json.dumps(
            {k: getattr(self, k) for k in ("source", "detail_type", "title", "source_ip", "resource")},
            sort_keys=True,
        )
        return hashlib.sha256(basis.encode("utf-8")).hexdigest()[:32]

    def rank(self) -> int:
        return SEVERITY.get(self.severity.lower(), 2)


def parse(data: dict[str, Any]) -> Finding:
    """Maakt een Finding van een eenvoudig JSON-object (bijvoorbeeld POST /events)."""

    title = data.get("title")
    if not isinstance(title, str) or not title.strip():
        raise ValueError("'title' is verplicht en mag niet leeg zijn.")
    severity = str(data.get("severity", "medium")).lower()
    if severity not in SEVERITY:
        raise ValueError(f"Onbekende ernst '{severity}'.")
    return Finding(
        id=str(data.get("id", "")),
        source=str(data.get("source", "cs2.demo")),
        detail_type=str(data.get("detail_type") or data.get("detail-type") or "Onbekend"),
        title=title,
        description=str(data.get("description", "")),
        severity=severity,
        source_ip=data.get("source_ip"),
        resource=data.get("resource"),
        raw=data,
    )


def _alarm_severity(name: str) -> str:
    name = name.lower()
    if any(word in name for word in ("cpu", "5xx", "unhealthy", "disk", "memory")):
        return "high"
    return "low" if "test" in name else "medium"


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
        name = detail.get("alarmName", "Onbekend alarm")
        return Finding(
            id=detail.get("alarmArn", ""),
            source="aws.cloudwatch",
            detail_type=detail_type,
            title=name,
            description=detail.get("alarmDescription", ""),
            severity=_alarm_severity(name),
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

    if "title" in event and "detail-type" not in event:
        return parse(event)

    return Finding(
        source=str(event.get("source", "onbekend")),
        detail_type=str(detail_type),
        title=str(event.get("title") or detail.get("title") or "Onbekende gebeurtenis"),
        description=str(event.get("description", "")),
        severity=str(event.get("severity", "medium")).lower(),
        raw=event,
    )


def load_rules(path: str | Path) -> list[dict[str, Any]]:
    return json.loads(Path(path).read_text(encoding="utf-8")).get("rules", [])


def matches(rule: dict[str, Any], finding: Finding) -> bool:
    when = rule.get("when", {})
    return (
        rule.get("enabled", True)
        and (not when.get("sources") or finding.source in when["sources"])
        and (not when.get("detail_types") or finding.detail_type in when["detail_types"])
        and finding.rank() >= SEVERITY.get(str(when.get("min_severity", "low")).lower(), 1)
        and (
            not when.get("title_contains")
            or any(word.lower() in finding.title.lower() for word in when["title_contains"])
        )
        and (not when.get("has_source_ip") or bool(finding.source_ip))
    )


def best_rule(rules: list[dict[str, Any]], finding: Finding) -> dict[str, Any] | None:
    """Hoogste prioriteit wint; bij een gelijke stand de eerst gedefinieerde regel."""

    found = [rule for rule in rules if matches(rule, finding)]
    return max(found, key=lambda rule: rule.get("priority", 0)) if found else None


def planned_actions(rule: dict[str, Any] | None) -> list[str]:
    return [action for action in ACTIONS if rule and action in rule.get("then", [])]
