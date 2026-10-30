# CS2-MA-NCA — Infrastructure as Code

Deze repository is de uitvoering van het ontwerp uit
`Design Document CS2 - volledig in de cloud.docx`. De omgeving draait volledig
in AWS (`eu-central-1`), zonder on-premises componenten, VPN of BGP.

> De vorige opdracht (CS1, de hub-and-spoke-omgeving) staat ongewijzigd in
> [`archive/cs1/`](archive/cs1/). Die bestanden doen niet meer mee: de
> workflows daar draaien niet, omdat GitHub alleen `.github/workflows/` in de
> root leest.

| Onderdeel | Uitvoering in deze repository |
|---|---|
| Netwerk | Platform-VPC `10.10.0.0/16` + Workload-VPC `10.20.0.0/16`, verbonden met een Transit Gateway |
| Toegang | SSM Session Manager; geen publieke SSH/RDP en geen bastion |
| Observability | Grafana + Loki op een private EC2, Grafana Alloy op de servers, AMP voor metrics, CloudWatch voor AWS-logs en flow logs |
| SOAR | FastAPI op ECS Fargate (2 taken), interne ALB, SQS + DLQ, EventBridge, DynamoDB-dedupe, Lambda-acties |
| Audit | Aurora Serverless v2 (append-only tabel) + S3 met versioning |
| Updates | Ansible via GitHub Actions op een self-hosted runner; SSH-sleutel in SSM |
| CI/CD | GitHub Actions met OIDC naar AWS; `ci.yml`, `deploy-soar.yml`, `ansible-update.yml` |
| Firewall | Gesimuleerde firewall-API: API Gateway → Lambda → DynamoDB |

## Snel starten

```bash
# vanuit de root van deze repository
cp infra/terraform.tfvars.example infra/terraform.tfvars
# pas owner, github_repo en alert_email aan

terraform -chdir=infra init
terraform -chdir=infra apply

./scripts/build_push.sh          # eerste keer: de ECR-repo is nog leeg
./scripts/register_runner.sh <github-pat> <owner/repo>   # optioneel
```

Daarna:

```bash
./scripts/port-forward.sh grafana   # http://localhost:3000
./scripts/port-forward.sh soar      # http://localhost:8080
```

De volledige demo staat in **[docs/DEMO.md](docs/DEMO.md)**.

## Repository-indeling

```
infra/                 Terraform: netwerk, IAM, observability, SOAR, database, runner
infra/templates/       User-data scripts voor de drie EC2-rollen
soar/                  FastAPI-applicatie, regelmotor, acties en audit
lambda/                Gesimuleerde firewall-API
grafana/               Datasources en dashboards (provisioning)
ansible/               Inventory, playbooks en rollen voor updates
.github/workflows/     CI, deploy, Terraform (optioneel) en Ansible
scripts/               Demo-, deploy-, audit- en hulpscripts
docs/                  Demo, kosten en ontwerpverantwoording
archive/cs1/           Vorige opdracht (hub-and-spoke), niet actief
```

## Belangrijk: kosten

Deze omgeving is bedoeld voor een demo, niet voor 24/7 productie. De grootste
posten zijn de Transit Gateway (~$ 73/maand) en twee NAT Gateways
(~$ 66/maand). Een dag demo kost ongeveer **$ 7–9**; 24/7 draaien kost
ongeveer **$ 285 per maand**. Zie [docs/KOSTEN.md](docs/KOSTEN.md).

```bash
./scripts/destroy.sh
```

## Wat bewust anders is dan het ontwerp

De code volgt het ontwerp, maar een aantal dure of niet-demonstratieve
onderdelen is weggelaten of anders ingevuld. De volledige onderbouwing staat
in **[docs/ONTWERP-VS-CODE.md](docs/ONTWERP-VS-CODE.md)**. De belangrijkste:

- **AWS Network Firewall** is niet gebouwd. In plaats daarvan is de
  gesimuleerde firewall-API (API Gateway → Lambda → DynamoDB) de actie die de
  SOAR uitvoert. Reden: ~$ 290/maand en de demo vraagt om een aantoonbare
  blokkade, niet om een echte pakketfilter.
- **NACL's** staan op default. Segmentatie gebeurt met Security Groups; dat is
  de leidende control in deze demo.
- **Windows-server** is niet gebouwd. Het ontwerp noemt hem, maar de demo
  gebruikt alleen Linux (AL2023). De Ansible-rol is voorbereid op Linux.
- **Object Lock** op de auditbucket is optioneel (`enable_object_lock`,
  standaard `false`), omdat het `destroy` blokkeert.
- **SOAR-quarantaine** schrijft een bewijsstuk naar S3 en tagt de instance;
  de netwerkisolatie zelf gebeurt niet automatisch.
- **Terraform-state** staat standaard lokaal. Een S3-backendvoorbeeld staat in
  `infra/backend.tf.example`.

## Voorwaarden

- Terraform ≥ 1.6 (ontwikkeld met 1.15)
- AWS CLI v2 met Session Manager-plugin
- Docker (voor het bouwen van de SOAR-image)
- `jq` en Python 3 voor de demo-scripts
- Een GitHub-repository (voor OIDC en de runner)

## Wat je kunt aantonen

| Eis | Bewijs in de demo |
|---|---|
| Netwerk gesegmenteerd | Twee VPC's, TGW, private subnetten, SG-overzicht |
| Geen publieke beheertoegang | SSM-sessies, geen publieke IP's |
| Observability | Grafana-dashboards, Loki-query, flow logs |
| SOAR reageert automatisch | `demo_attack.sh brute` → blokkade + audit + SNS |
| Audit | S3-object en rij in Aurora via `/audit/recent` |
| CI/CD met OIDC | GitHub Actions-run en nieuwe ECS-taakdefinitie |
| Centrale updates | Ansible-run met `changed=0` bij de tweede run |
| Kostenbewust | Budgetalarm en kostenoverzicht |
