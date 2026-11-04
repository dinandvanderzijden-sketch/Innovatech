# Waar staan de gegevens en de logs?

Deze omgeving heeft twee soorten opslag:

1. **Twee databases (Aurora)** — de audit van de SOAR en het gastenboek van
   de website. Ze zijn bewust gescheiden.
2. **Logs** — verspreid over CloudWatch, S3 en Loki, elk voor een ander doel.

De website is een Flask-app achter nginx en slaat berichten op in PostgreSQL.
De SOAR heeft een eigen database met het auditspoor.

---

## 1. De databases: twee Aurora-clusters

Er zijn twee aparte databases, met een bewuste scheiding:

| | Audit (SOAR) | Website |
|---|---|---|
| Cluster | `cs2-dev-aurora` | `cs2-dev-web-aurora` |
| Database | `soar` | `web` |
| Tabel | `audit_events` | `berichten` |
| Instanties | 2 (twee AZ's) | 1 (kostenkeuze) |
| Capaciteit | 0–2 ACU | 0–2 ACU |
| Doel | onweerlegbaar auditspoor | gastenboek van de website |

De website schrijft via Flask naar `berichten`; de SOAR schrijft naar
`audit_events`. Een storing of restore raakt maar één van de twee, en de
website heeft geen toegang tot de auditgegevens.

### Auditdatabase (SOAR)

| Eigenschap | Waarde |
|---|---|
| Engine | Aurora PostgreSQL 17 |
| Database | `soar` |
| Gebruiker | `soar_admin` (wachtwoord in Secrets Manager: `cs2-dev/db`) |
| Endpoint | `cs2-dev-aurora.cluster-….eu-central-1.rds.amazonaws.com` |
| Instanties | 2 (`db.serverless`), in `eu-central-1a` en `eu-central-1b` |
| Capaciteit | 0–2 ACU, schaalt na 5 minuten stilte naar 0 |
| Encryptie | Aan (opslag) |
| Back-up | Point-in-time, 1 dag |
| Netwerk | Private data-subnetten, geen publieke toegang |

### Wat staat erin (audit)?

Eén tabel: `audit_events`. De SOAR schrijft daar elke verwerkte gebeurtenis
in, met de regel die vuurde en de acties die zijn uitgevoerd.

| Kolom | Betekenis |
|---|---|
| `id` | Oplopend nummer |
| `correlation_id` | Unieke ID van het event |
| `occurred_at` | Tijdstip (UTC) |
| `source`, `detail_type` | Herkomst, bijvoorbeeld `cs2.demo` |
| `title`, `severity` | Wat er gebeurde en hoe ernstig |
| `source_ip`, `resource` | Betrokken IP of instance |
| `rules` | Welke SOAR-regel(s) matchten (JSON) |
| `actions` | Uitgevoerde acties met resultaat (JSON) |
| `payload` | Het volledige originele event (JSON) |

De tabel wordt bij de eerste verbinding automatisch aangemaakt
(`CREATE TABLE IF NOT EXISTS` in `soar/app/audit.py`). Er is geen update- of
delete-pad: auditregels worden alleen toegevoegd.

### Websitedatabase

De pagina toont zelf het aantal berichten. Voor de ruwe data:

```bash
curl "http://localhost:8081/api/berichten" | jq .
```

De app maakt de tabel bij de eerste verbinding aan. De mastergegevens staan
in Secrets Manager (`cs2-dev/web-db`).

### Hoe bekijk je de inhoud van de auditdatabase?

**Makkelijkst — via de SOAR-API:**

```bash
./scripts/port-forward.sh soar
curl "http://localhost:8080/audit/recent?limit=10" | jq .
```

**De infrastructuur zelf:**

```bash
aws rds describe-db-clusters --db-cluster-identifier cs2-dev-aurora \
  --query 'DBClusters[0].{status:Status,engine:Engine,endpoint:Endpoint,acu:ServerlessV2ScalingConfiguration}' \
  --output json

aws rds describe-db-instances \
  --query 'DBInstances[?contains(DBInstanceIdentifier, `cs2-dev`)].{id:DBInstanceIdentifier,az:AvailabilityZone,status:DBInstanceStatus}' \
  --output table
```

**Direct SQL — bekijk de tabellen en rijen:**

De databases zijn privé, dus psql draait op de runner (binnen de VPC) en het
script stuurt de query daarheen. Het wachtwoord blijft in Secrets Manager.

```bash
./scripts/db_query.sh                  # website: \dt + laatste berichten
./scripts/db_query.sh audit            # audit: \dt + laatste events
./scripts/db_query.sh web "select count(*) from berichten;"
./scripts/db_query.sh web "\d berichten"        # kolommen en types
./scripts/db_query.sh audit "select severity, count(*) from audit_events group by severity;"
```

De eerste keer installeert het script de PostgreSQL-client op de runner
(±30 seconden). Let op: dit is een echte SQL-sessie, dus een `insert` of
`delete` wordt ook uitgevoerd.

---

## 2. Waar staan de logs?

Elke logsoort heeft een eigen plek. Dit is de complete kaart:

| Wat | Waar | Bewaartermijn | Zo bekijk je het |
|---|---|---|---|
| SOAR-applicatie (verwerkte events, fouten) | CloudWatch `/aws/ecs/cs2-dev-soar` | 30 dagen | `./scripts/show_audit.sh --follow` |
| Netwerkverkeer (VPC Flow Logs) | CloudWatch `/aws/vpc/cs2-dev/flowlogs` | 30 dagen | `aws logs tail /aws/vpc/cs2-dev/flowlogs --follow` |
| Firewall-Lambda | CloudWatch `/aws/lambda/cs2-dev-firewall-api` | 30 dagen | Console → CloudWatch → Log groups |
| Image-builds | CloudWatch `/aws/codebuild/cs2-dev-soar-build` | 30 dagen | Console, of de Deploy-run |
| OS-logs van de servers (syslog) | Loki, en als bestand `/var/log/remote/<host>.log` op de observability-host | 30 dagen (Loki) | Grafana → Explore → `{job="syslog"}` |
| systemd-journal van de servers | Loki | 30 dagen | Grafana → Explore → `{job="systemd-journal"}` |
| Audit + incidenten (definitief) | S3 `cs2-dev-audit-…` → `events/` | 365 dagen | `./scripts/show_audit.sh --latest` |
| Quarantainebewijs | S3 `cs2-dev-audit-…` → `quarantine/` | 365 dagen | `aws s3 ls s3://<bucket>/quarantine/` |
| Loki-opslag (chunks + index) | S3 `cs2-dev-loki-…` | 37 dagen | Indirect, via Grafana |
| Grafana-provisioning, build-zip, Ansible-rapporten | S3 `cs2-dev-artifacts-…` | — | `aws s3 ls s3://<bucket>/` |

De bucket-namen hebben een random suffix. Laat ze altijd opvragen:

```bash
./scripts/logs_overview.sh
```

### De drie belangrijkste routes

**A. Applicatielogs (CloudWatch)**

```bash
./scripts/show_audit.sh --follow
# of
aws logs tail /aws/ecs/cs2-dev-soar --follow --since 15m
```

**B. Serverlogs (Loki, via Grafana)**

```bash
./scripts/port-forward.sh grafana     # http://localhost:3000
```

Ga naar **Explore → Loki** en gebruik:

```logql
{job="syslog"} |= "sshd"
{job="syslog", filename=~".*ip-10-20.*"}
{job="systemd-journal"} |= "error"
```

**C. Audit (S3 + database)**

```bash
./scripts/show_audit.sh              # laatste objecten in S3
./scripts/show_audit.sh --latest     # inhoud van het nieuwste object
./scripts/port-forward.sh soar
curl "http://localhost:8080/audit/recent?limit=10" | jq .
```

---

## 3. Welke bron voor welke vraag?

| Vraag | Bron |
|---|---|
| Wat heeft de SOAR met dit incident gedaan? | `events/` in S3 + `/audit/recent` |
| Waarom crashte de SOAR-container? | CloudWatch `/aws/ecs/cs2-dev-soar` |
| Wie maakte verbinding met welke poort? | VPC Flow Logs |
| Wat gebeurde er op de Linux-server zelf? | Loki `{job="syslog"}` |
| Is de image-build geslaagd? | CloudWatch CodeBuild + Deploy-run |
| Wat heeft Ansible aangepast? | S3 `artifacts/reports/` |

---

## 4. Bewaartermijnen instellen

| Instelling | Variabele | Standaard |
|---|---|---|
| Audit in S3 | `audit_retention_days` | 365 |
| Loki | `loki_retention_hours` | 720 (30 dagen) |
| CloudWatch SOAR | vast in `infra/soar.tf` | 30 dagen |
| Flow logs / Lambda | vast in `infra/observability.tf` | 30 dagen |

Pas je een waarde aan, dan rolt de Deploy-workflow hem uit. Let op: CloudWatch
bewaart oude logstreams tot de ingestelde termijn; S3-levensduur verwijdert
objecten automatisch.
