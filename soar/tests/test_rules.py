"""Tests voor de regelmotor en de normalisatie van events."""

from pathlib import Path

from app.models import Finding, normalize_event
from app.rules import RuleSet, planned_actions

RULES_PATH = Path(__file__).resolve().parents[1] / "rules.json"


def _ruleset() -> RuleSet:
    return RuleSet.load(RULES_PATH)


def test_cpu_alarm_wordt_genormaliseerd():
    event = {
        "source": "aws.cloudwatch",
        "detail-type": "CloudWatch Alarm State Change",
        "detail": {
            "alarmName": "cs2-dev-cpu-0",
            "alarmDescription": "CPU boven 80%",
            "state": {"value": "ALARM"},
            "configuration": {
                "metrics": [
                    {
                        "metricStat": {
                            "metric": {
                                "namespace": "AWS/EC2",
                                "name": "CPUUtilization",
                                "dimensions": {"InstanceId": "i-0123456789abcdef0"},
                            }
                        }
                    }
                ]
            },
        },
    }

    finding = normalize_event(event)

    assert finding.source == "aws.cloudwatch"
    assert finding.title == "cs2-dev-cpu-0"
    assert finding.severity == "high"
    assert finding.resource == "i-0123456789abcdef0"


def test_brute_force_regel_blokkeert_ip():
    finding = Finding(
        source="cs2.demo",
        detail_type="CS2 Security Finding",
        title="SSH brute force gedetecteerd",
        severity="high",
        source_ip="203.0.113.7",
    )

    selected = _ruleset().select(finding)

    assert [rule.id for rule in selected] == ["R-110"]
    assert planned_actions(selected) == ["block_ip", "notify"]


def test_brute_force_zonder_ip_matcht_niet():
    finding = Finding(
        source="cs2.demo",
        detail_type="CS2 Security Finding",
        title="SSH brute force gedetecteerd",
        severity="high",
    )

    ids = {rule.id for rule in _ruleset().match(finding)}

    assert "R-110" not in ids


def test_lage_ernst_matcht_geen_medium_regel():
    finding = Finding(
        source="aws.cloudwatch",
        detail_type="CloudWatch Alarm State Change",
        title="cpu testalarm",
        severity="low",
    )

    ids = {rule.id for rule in _ruleset().match(finding)}

    assert "SOAR-001" not in ids


def test_kritieke_bevinding_valt_terug_op_melden():
    finding = Finding(
        source="onbekend",
        detail_type="Onbekend",
        title="Iets ernstigs",
        severity="critical",
    )

    selected = _ruleset().select(finding)

    assert [rule.id for rule in selected] == ["SOAR-006"]
    assert planned_actions(selected) == ["notify"]


def test_hoogste_prioriteit_wint():
    # Dit event past op R-110 (blokkeren) en SOAR-003 (quarantaine).
    # R-110 heeft prioriteit 200 en wint dus.
    finding = Finding(
        source="cs2.demo",
        detail_type="CS2 Security Finding",
        title="Malware en brute force",
        severity="critical",
        source_ip="198.51.100.9",
    )

    selected = _ruleset().select(finding)

    assert len(selected) == 1
    assert selected[0].id == "R-110"
    assert planned_actions(selected) == ["block_ip", "notify"]


def test_malware_krijgt_quarantaine():
    finding = Finding(
        source="cs2.demo",
        detail_type="CS2 Security Finding",
        title="Malware en C2-verkeer",
        severity="critical",
    )

    selected = _ruleset().select(finding)

    assert [rule.id for rule in selected] == ["SOAR-003"]
    assert planned_actions(selected) == ["quarantine", "notify"]


def test_correlation_id_is_stabiel():
    finding = Finding(
        source="cs2.demo",
        detail_type="CS2 Security Finding",
        title="Poortscan",
        severity="medium",
        source_ip="198.51.100.10",
    )

    assert finding.correlation_id() == finding.correlation_id()
    assert len(finding.correlation_id()) == 32
