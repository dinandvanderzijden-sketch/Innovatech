"""Regelmotor: bepaalt welke acties bij een bevinding horen."""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .models import SEVERITY_ORDER, Finding

logger = logging.getLogger(__name__)

ALLOWED_ACTIONS = {"block_ip", "notify", "quarantine"}


@dataclass(frozen=True)
class Rule:
    id: str
    name: str
    enabled: bool
    severity: str
    actions: tuple[str, ...]
    sources: tuple[str, ...] = ()
    detail_types: tuple[str, ...] = ()
    min_severity: str = "low"
    title_regex: str = ""
    require_source_ip: bool = False
    priority: int = 0

    def matches(self, finding: Finding) -> bool:
        if not self.enabled:
            return False

        if self.sources and finding.source not in self.sources:
            return False

        if self.detail_types and finding.detail_type not in self.detail_types:
            return False

        if finding.severity_rank() < SEVERITY_ORDER.get(self.min_severity, 1):
            return False

        if self.title_regex and not re.search(self.title_regex, finding.title):
            return False

        if self.require_source_ip and not finding.source_ip:
            return False

        return True

    def as_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "enabled": self.enabled,
            "severity": self.severity,
            "actions": list(self.actions),
            "min_severity": self.min_severity,
            "title_regex": self.title_regex,
            "require_source_ip": self.require_source_ip,
            "priority": self.priority,
        }


@dataclass
class RuleSet:
    rules: list[Rule] = field(default_factory=list)

    def match(self, finding: Finding) -> list[Rule]:
        """Alle passende regels, in de volgorde waarin ze zijn gedefinieerd."""

        return [rule for rule in self.rules if rule.matches(finding)]

    def select(self, finding: Finding) -> list[Rule]:
        """De winnende regel: hoogste prioriteit, bij een gelijke stand de eerste."""

        candidates = self.match(finding)
        if not candidates:
            return []

        best = max(rule.priority for rule in candidates)
        return [next(rule for rule in candidates if rule.priority == best)]

    @staticmethod
    def load(path: str | Path) -> "RuleSet":
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        rules: list[Rule] = []

        for raw in data.get("rules", []):
            actions = tuple(a for a in raw.get("actions", []) if a in ALLOWED_ACTIONS)
            unknown = set(raw.get("actions", [])) - ALLOWED_ACTIONS
            if unknown:
                logger.warning("Regel %s bevat onbekende acties: %s", raw.get("id"), unknown)

            if not actions:
                logger.warning("Regel %s heeft geen geldige acties en wordt overgeslagen.", raw.get("id"))
                continue

            rules.append(
                Rule(
                    id=str(raw.get("id", "")),
                    name=str(raw.get("name", "")),
                    enabled=bool(raw.get("enabled", True)),
                    severity=str(raw.get("severity", "medium")).lower(),
                    actions=actions,
                    sources=tuple(raw.get("sources", [])),
                    detail_types=tuple(raw.get("detail_types", [])),
                    min_severity=str(raw.get("min_severity", "low")).lower(),
                    title_regex=str(raw.get("title_regex", "")),
                    require_source_ip=bool(raw.get("require_source_ip", False)),
                    priority=int(raw.get("priority", 0)),
                )
            )

        logger.info("%d regels geladen uit %s", len(rules), path)
        return RuleSet(rules=rules)


def planned_actions(rules: list[Rule]) -> list[str]:
    """Unie van acties, in een vaste uitvoeringsvolgorde."""

    selected = {action for rule in rules for action in rule.actions}
    return [a for a in ("block_ip", "quarantine", "notify") if a in selected]
