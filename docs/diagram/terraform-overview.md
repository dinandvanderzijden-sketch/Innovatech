# Terraform-overzicht

Dit diagram wordt gegenereerd uit `infra/*.tf` door `scripts/terraform_overview.py`.
Het toont de lagen en de belangrijkste stromen. Voor de volledige afhankelijkheden
per resource: zie `terraform-rover.svg`.

```mermaid
flowchart TB
  classDef net fill:#EAF2FA,stroke:#12355B,color:#12355B
  classDef sec fill:#FBEDEA,stroke:#A93226,color:#A93226
  classDef web fill:#E9F4F2,stroke:#1F6F6B,color:#1F6F6B
  classDef data fill:#FBF2E7,stroke:#C26A1B,color:#C26A1B
  classDef obs fill:#F2F6FA,stroke:#5A6B7B,color:#5A6B7B
  classDef dev fill:#EDE9FE,stroke:#6D28D9,color:#6D28D9

  GH["GitHub Actions<br/>CI · Deploy · Destroy"]:::dev

  subgraph NET["Netwerk (49 resources)"]
    TGW["Transit Gateway"]
    VPCP["Platform-VPC<br/>10.10.0.0/16"]
    VPCW["Workload-VPC<br/>10.20.0.0/16"]
    NAT["NAT Gateway (2)"]
    DNS["Route 53<br/>innovatech.internal"]
  end

  subgraph SEC["Beveiliging (33 resources)"]
    SSM["SSM Session Manager"]
    SG["Security Groups"]
    FW["Firewall-API<br/>API Gateway → Lambda"]
    BLOCK[("DynamoDB<br/>blocked-ips")]
  end

  subgraph WEB["Websites (9 resources)"]
    ALB["Interne ALB<br/>listener 8080"]
    W1["Webserver 1<br/>nginx + Flask"]
    W2["Webserver 2<br/>nginx + Flask"]
  end

  subgraph DATA["Databases (14 resources)"]
    AUD[("Aurora audit<br/>audit_events")]
    WEBDB[("Aurora web<br/>berichten")]
  end

  subgraph OBS["Observability (16 resources)"]
    GRAF["Grafana"]
    LOKI["Loki + S3"]
    PROM["Prometheus"]
    ALLOY["Grafana Alloy"]
    CW["CloudWatch"]
  end

  subgraph SOAR["SOAR (23 resources)"]
    EB["EventBridge"]
    SQS["SQS + DLQ"]
    ECS["ECS Fargate<br/>2 taken"]
    SNS["SNS"]
  end

  subgraph STORE["Opslag (20 resources)"]
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
```

## Resources per laag

| Laag | Aantal resources |
|---|---|
| Netwerk | 49 |
| Beveiliging | 33 |
| Websites | 9 |
| Databases | 14 |
| Opslag | 20 |
| Observability | 16 |
| SOAR | 23 |
| DevOps | 1 |
