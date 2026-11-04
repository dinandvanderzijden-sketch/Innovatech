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
| Websites | nginx + Flask op de twee servers, met een eigen Aurora-database (gastenboek); interne ALB op poort 8080, bekijken via `./scripts/port-forward.sh web` |
| Observability | Grafana + Loki + Prometheus op een private EC2, Grafana Alloy op de servers, CloudWatch voor AWS-logs en flow logs |
| SOAR | FastAPI op ECS Fargate (2 taken), interne ALB, SQS + DLQ, EventBridge, DynamoDB-dedupe, Lambda-acties |
| Audit | Aurora Serverless v2 (append-only tabel) + S3 met versioning |
| Updates | Ansible via GitHub Actions op een self-hosted runner; SSH-sleutel in SSM |
| CI/CD | Push naar `main` = tests + `terraform apply` + image-build (CodeBuild); `destroy.yml` zet alles met één knop uit; OIDC, geen vaste sleutels |
| Firewall | Gesimuleerde firewall-API: API Gateway → Lambda → DynamoDB |

## Snel starten

Eenmalig lokaal (maakt de state-bucket, de GitHub-rol en de omgeving):

```bash
./scripts/bootstrap_state.sh
```

Daarna gaat alles via GitHub:

1. **Deploy** — elke push naar `main` die `infra/`, `soar/`, `lambda/` of
   `grafana/` raakt: tests → `terraform apply` → image bouwen en uitrollen.
   Handmatig starten kan ook via **Actions → Deploy → Run workflow**.
2. **Destroy** — **Actions → Destroy → Run workflow**, typ `DESTROY`.
   De state-bucket en de GitHub-rol blijven staan, zodat een volgende Deploy
   gewoon weer werkt.

Lokaal werken kan ook:

```bash
terraform -chdir=infra plan
./scripts/build_codebuild.sh     # image bouwen zonder Docker
./scripts/register_runner.sh <github-pat> <owner/repo>   # optioneel
```

Daarna:

```bash
./scripts/port-forward.sh grafana   # http://localhost:3000
./scripts/port-forward.sh soar      # http://localhost:8080
./scripts/port-forward.sh web       # http://localhost:8081
```

De volledige demo staat in **[docs/DEMO.md](docs/DEMO.md)**.
Waar alle logs en de database staan: **[docs/LOGGING.md](docs/LOGGING.md)**.

## Repository-indeling

```
infra/                 Terraform: netwerk, IAM, observability, SOAR, database, runner
infra/backend.tf       Gedeelde S3-state (bucket + lock)
infra/web.tf           nginx-websites achter de interne ALB
bootstrap/             Eenmalig: GitHub OIDC-rol + provider (overleeft destroy)
infra/templates/       User-data scripts voor de drie EC2-rollen
soar/                  FastAPI-applicatie, regelmotor, acties en audit
lambda/                Gesimuleerde firewall-API
grafana/               Datasources en dashboards (provisioning)
ansible/               Inventory, playbooks en rollen voor updates
.github/workflows/     CI, Deploy, Destroy en Ansible
scripts/               Demo-, deploy-, audit- en hulpscripts
docs/                  Demo, kosten, logging en ontwerpverantwoording
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
- **Terraform-state** staat in S3 (`infra/backend.tf`), zodat GitHub Actions
  en je laptop dezelfde omgeving beheren. De bucket en de GitHub-rol staan in
  `bootstrap/` en worden bewust niet door `destroy` verwijderd.

## Voorwaarden

- Terraform ≥ 1.6 (ontwikkeld met 1.15)
- AWS CLI v2 met Session Manager-plugin
- Docker (optioneel; zonder Docker gebruik je `./scripts/build_codebuild.sh`)
- `boto3` voor `scripts/send_event.py` (`python3 -m pip install --user boto3`)
- `jq` en Python 3 voor de demo-scripts
- Een GitHub-repository (voor OIDC en de runner)

## Wat je kunt aantonen

| Eis | Bewijs in de demo |
|---|---|
| Netwerk gesegmenteerd | Twee VPC's, TGW, private subnetten, SG-overzicht |
| Werkende websites | `port-forward.sh web` → gastenboek; berichten blijven staan en zijn door beide servers geschreven |
| Website met database | Eigen Aurora-cluster `web`, tabel `berichten`; bewijs via `/api/berichten` en `terraform output web_db_endpoint` |
| Geen publieke beheertoegang | SSM-sessies, geen publieke IP's |
| Observability | Grafana-dashboards, Loki-query, flow logs |
| SOAR reageert automatisch | `demo_attack.sh brute` → blokkade + audit + SNS |
| Audit | S3-object en rij in Aurora via `/audit/recent` |
| CI/CD met OIDC | GitHub Actions-run en nieuwe ECS-taakdefinitie |
| Centrale updates | Ansible-run met `changed=0` bij de tweede run |
| Kostenbewust | Budgetalarm en kostenoverzicht |
