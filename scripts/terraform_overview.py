#!/usr/bin/env python3
"""Genereert een leesbaar overzichtsdiagram uit de Terraform-code.

Rover tekent elke resource en elke afhankelijkheid; dat is compleet maar
onleesbaar. Dit script leest de .tf-bestanden, telt de resources per laag en
zet een gelaagd Mermaid-diagram neer met alleen de hoofdonderdelen en de
belangrijkste stromen.

Gebruik:
    python3 scripts/terraform_overview.py
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    import hcl2
except ImportError:
    print("Installeer eerst python-hcl2: pip install python-hcl2", file=sys.stderr)
    raise SystemExit(1)

ROOT = Path(__file__).resolve().parents[1]
INFRA = ROOT / "infra"
OUT = ROOT / "docs" / "diagram"

# type-prefix -> (laag, label)
LAYERS = [
    ("Netwerk", [
        "aws_vpc", "aws_subnet", "aws_route_table", "aws_route",
        "aws_internet_gateway", "aws_nat_gateway", "aws_eip",
        "aws_ec2_transit_gateway", "aws_vpc_endpoint",
    ]),
    ("Beveiliging", [
        "aws_security_group", "aws_iam_", "aws_kms_", "aws_key_pair",
    ]),
    ("Websites", [
        "aws_lb", "aws_instance", "aws_launch_template",
    ]),
    ("Databases", [
        "aws_rds_", "aws_db_", "aws_secretsmanager_secret",
    ]),
    ("Opslag", [
        "aws_s3_",
    ]),
    ("Observability", [
        "aws_cloudwatch_", "aws_flow_log",
    ]),
    ("SOAR", [
        "aws_ecs_", "aws_ecr_", "aws_sqs_", "aws_cloudwatch_event_",
        "aws_lambda_", "aws_api_gateway_", "aws_dynamodb_", "aws_sns_",
    ]),
    ("DevOps", [
        "aws_codebuild_", "aws_route53_",
    ]),
]


def load_resources():
    resources = []
    for path in sorted(INFRA.glob("*.tf")):
        data = hcl2.loads(path.read_text(encoding="utf-8"))
        for block in data.get("resource", []):
            for rtype, entries in block.items():
                for name in entries:
                    resources.append((rtype.strip('"'), name.strip('"'), path.name))
    return resources


def layer_of(rtype):
    for layer, prefixes in LAYERS:
        for prefix in prefixes:
            if rtype == prefix or rtype.startswith(prefix):
                return layer
    return None


def build_mermaid(resources):
    counts = {}
    for rtype, name, _ in resources:
        layer = layer_of(rtype)
        if layer:
            counts.setdefault(layer, []).append(rtype)

    def n(layer):
        return len(counts.get(layer, []))

    return f"""flowchart TB
  classDef net fill:#EAF2FA,stroke:#12355B,color:#12355B
  classDef sec fill:#FBEDEA,stroke:#A93226,color:#A93226
  classDef web fill:#E9F4F2,stroke:#1F6F6B,color:#1F6F6B
  classDef data fill:#FBF2E7,stroke:#C26A1B,color:#C26A1B
  classDef obs fill:#F2F6FA,stroke:#5A6B7B,color:#5A6B7B
  classDef dev fill:#EDE9FE,stroke:#6D28D9,color:#6D28D9

  GH["GitHub Actions<br/>CI · Deploy · Destroy"]:::dev

  subgraph NET["Netwerk ({n('Netwerk')} resources)"]
    TGW["Transit Gateway"]
    VPCP["Platform-VPC<br/>10.10.0.0/16"]
    VPCW["Workload-VPC<br/>10.20.0.0/16"]
    NAT["NAT Gateway (2)"]
    DNS["Route 53<br/>innovatech.internal"]
  end

  subgraph SEC["Beveiliging ({n('Beveiliging')} resources)"]
    SSM["SSM Session Manager"]
    SG["Security Groups"]
    FW["Firewall-API<br/>API Gateway → Lambda"]
    BLOCK[("DynamoDB<br/>blocked-ips")]
  end

  subgraph WEB["Websites ({n('Websites')} resources)"]
    ALB["Interne ALB<br/>listener 8080"]
    W1["Webserver 1<br/>nginx + Flask"]
    W2["Webserver 2<br/>nginx + Flask"]
  end

  subgraph DATA["Databases ({n('Databases')} resources)"]
    AUD[("Aurora audit<br/>audit_events")]
    WEBDB[("Aurora web<br/>berichten")]
  end

  subgraph OBS["Observability ({n('Observability')} resources)"]
    GRAF["Grafana"]
    LOKI["Loki + S3"]
    PROM["Prometheus"]
    ALLOY["Grafana Alloy"]
    CW["CloudWatch"]
  end

  subgraph SOAR["SOAR ({n('SOAR')} resources)"]
    EB["EventBridge"]
    SQS["SQS + DLQ"]
    ECS["ECS Fargate<br/>2 taken"]
    SNS["SNS"]
  end

  subgraph STORE["Opslag ({n('Opslag')} resources)"]
    AUDIT["S3 audit"]
    LOKIS3["S3 Loki"]
    ART["S3 artifacts"]
  end

  GH -->|terraform apply| TGW
  GH -->|image + taakdefinitie| ECS
  GH -->|state| ART

  TGW --- VPCP
  TGW --- VPCW
  VPCP --- NAT
  VPCP --- DNS
  SG --- ALB
  SG --- W1
  SG --- W2
  SSM --- W1
  SSM --- W2

  ALB -->|8080| W1
  ALB -->|8080| W2
  W1 -->|5432| WEBDB
  W2 -->|5432| WEBDB

  EB -->|alarm of bevinding| SQS
  SQS --> ECS
  ECS -->|notify| SNS
  ECS -->|block_ip| FW
  FW --> BLOCK
  ECS -->|audit| AUD
  ECS -->|auditobject| AUDIT

  ALLOY -->|metrics| PROM
  ALLOY -->|logs| LOKI
  LOKI --- LOKIS3
  GRAF --> PROM
  GRAF --> LOKI
  GRAF --> CW
  W1 -.->|syslog + metrics| ALLOY
  W2 -.->|syslog + metrics| ALLOY
  EB -.->|alarmen| CW

  class TGW,VPCP,VPCW,NAT,DNS net
  class SSM,SG,FW,BLOCK sec
  class ALB,W1,W2 web
  class AUD,WEBDB data
  class GRAF,LOKI,PROM,ALLOY,CW obs
  class EB,SQS,ECS,SNS net
  class AUDIT,LOKIS3,ART data
"""


def main() -> int:
    resources = load_resources()
    if not resources:
        print("Geen resources gevonden in infra/.", file=sys.stderr)
        return 1

    OUT.mkdir(parents=True, exist_ok=True)
    mermaid = build_mermaid(resources)
    (OUT / "terraform-overview.mmd").write_text(mermaid, encoding="utf-8")

    markdown = f"""# Terraform-overzicht

Dit diagram wordt gegenereerd uit `infra/*.tf` door `scripts/terraform_overview.py`.
Het toont de lagen en de belangrijkste stromen. Voor de volledige afhankelijkheden
per resource: zie `terraform-rover.svg`.

```mermaid
{mermaid}```

## Resources per laag

| Laag | Aantal resources |
|---|---|
"""
    counts = {}
    for rtype, _, _ in resources:
        layer = layer_of(rtype)
        if layer:
            counts[layer] = counts.get(layer, 0) + 1
    for layer, _ in LAYERS:
        markdown += f"| {layer} | {counts.get(layer, 0)} |\n"

    (OUT / "terraform-overview.md").write_text(markdown, encoding="utf-8")
    print(f"geschreven: {OUT / 'terraform-overview.md'} en .mmd ({len(resources)} resources)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
