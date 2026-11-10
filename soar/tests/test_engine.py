"""Tests voor de spellogica. Er is geen AWS-omgeving nodig."""

from pathlib import Path

import pytest

from app.engine import Finding, best_rule, load_rules, matches, normalize_event, parse, planned_actions

RULES_PATH = Path(__file__).resolve().parents[1] / "rules.json"


def _rules():
    return load_rules(RULES_PATH)


def test_cpu_alarm_wordt_genormaliseerd():
    event = {
        "source": "aws.cloudwatch",
        "detail-type": "CloudWatch Alarm State Change",
        "detail": {
            "alarmName": "cs2-dev-cpu-0",
            "alarmDescription": "CPU boven 80%",
            "state": {"value": "ALARM"},
            "configuration": {
                "metrics": [{
                    "metricStat": {
                        "metric": {
                            "namespace": "AWS/EC2",
                            "name": "CPUUtilization",
                            "dimensions": {"InstanceId": "i-0123456789abcdef0"},
                        }
                    }
                }]
            },
        },
    }

    finding = normalize_event(event)

    assert (finding.source, finding.title, finding.severity) == (
        "aws.cloudwatch", "cs2-dev-cpu-0", "high"
    )
    assert finding.resource == "i-0123456789abcdef0"


def test_brute_force_regel_blokkeert_ip():
    finding = Finding(
        source="cs2.demo",
        detail_type="CS2 Security Finding",
        title="SSH brute force gedetecteerd",
        severity="high",
        source_ip="203.0.113.7",
    )

    rule = best_rule(_rules(), finding)

    assert rule["id"] == "R-110"
    assert planned_actions(rule) == ["block_ip", "notify"]


def test_brute_force_zonder_ip_matcht_niet():
    finding = Finding(
        source="cs2.demo",
        detail_type="CS2 Security Finding",
        title="SSH brute force gedetecteerd",
        severity="high",
    )

    rule = next(rule for rule in _rules() if rule["id"] == "R-110")

    assert not matches(rule, finding)


def test_lage_ernst_matcht_geen_medium_regel():
    finding = Finding(
        source="aws.cloudwatch",
        detail_type="CloudWatch Alarm State Change",
        title="cpu testalarm",
        severity="low",
    )

    rule = next(rule for rule in _rules() if rule["id"] == "SOAR-001")

    assert not matches(rule, finding)


def test_kritieke_bevinding_valt_terug_op_melden():
    finding = Finding(
        source="onbekend",
        detail_type="Onbekend",
        title="Iets ernstigs",
        severity="critical",
    )

    rule = best_rule(_rules(), finding)

    assert rule["id"] == "SOAR-006"
    assert planned_actions(rule) == ["notify"]


def test_hoogste_prioriteit_wint():
    # Dit event past op R-110 (blokkeren) en SOAR-003 (quarantaine).
    finding = Finding(
        source="cs2.demo",
        detail_type="CS2 Security Finding",
        title="Malware en brute force",
        severity="critical",
        source_ip="198.51.100.9",
    )

    rule = best_rule(_rules(), finding)

    assert rule["id"] == "R-110"
    assert planned_actions(rule) == ["block_ip", "notify"]


def test_malware_krijgt_quarantaine():
    finding = Finding(
        source="cs2.demo",
        detail_type="CS2 Security Finding",
        title="Malware en C2-verkeer",
        severity="critical",
    )

    rule = best_rule(_rules(), finding)

    assert rule["id"] == "SOAR-003"
    assert planned_actions(rule) == ["quarantine", "notify"]


def test_titel_zoeken_is_hoofdletterongevoelig():
    finding = Finding(
        source="cs2.demo",
        detail_type="CS2 Security Finding",
        title="SSH BRUTE FORCE",
        severity="high",
        source_ip="203.0.113.8",
    )

    assert best_rule(_rules(), finding)["id"] == "R-110"


def test_ongeldige_bevinding_geeft_duidelijke_fout():
    with pytest.raises(ValueError, match="title"):
        parse({"severity": "high"})


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
