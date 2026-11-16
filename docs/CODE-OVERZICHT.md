# Code-overzicht CS2

Doel: snel kunnen antwoorden op vragen over de code, en weten waar je een wijziging maakt tijdens de demo.
De repo is `cs2-platform`. Alles draait in AWS `eu-central-1`.

---

## 1. Repository-indeling

| Map | Wat erin zit |
|---|---|
| `infra/` | Alle Terraform voor de AWS-omgeving (VPC's, databases, ECS, SQS, Lambda, EC2, buckets, alarmen) |
| `soar/` | De SOAR-applicatie: spellogica, API, SQS-worker en de regels |
| `soar/app/` | `engine.py` (pure logica), `main.py` (API + worker), `effects.py` (bijwerkingen), `config.py` (instellingen) |
| `soar/tests/` | pytest-tests voor de spellogica |
| `soar/rules.json` | De detectieregels (R-110, SOAR-003, …) |
| `lambda/` | `firewall_api.py` — gesimuleerde firewall-API (zet een IP-blokkade in DynamoDB) |
| `webapp/` | `app.py` — het gastenboek (Flask + PostgreSQL) |
| `ansible/` | Updates over de servers: playbook + rollen + inventory |
| `grafana/` | Dashboards (`dashboards/`) en provisioning (`provisioning/`) |
| `scripts/` | Demo- en beheerscripts (aanvallen, tunnels, audit, …) |
| `.github/workflows/` | CI/CD: `deploy.yml`, `ci.yml`, `ansible-update.yml`, `destroy.yml` |
| `bootstrap/` | Eenmalige Terraform voor de state-bucket en de GitHub-OIDC-rol |
| `docs/` | Documentatie en bewijs (wordt niet gedeployed) |
| `archive/cs1/` | Oude CS1-code, staat los van CS2 |

---

## 2. De SOAR-keten (event → actie → bewijs)

Eén event loopt als volgt door de code:

```
EventBridge / scripts/demo_attack.sh
   → SQS-wachtrij (infra/soar.tf)
   → SOAR-worker (soar/app/main.py: _worker)
   → main.py: process()
       → engine.py: normalize_event()  → Finding
       → engine.py: best_rule()        → hoogste prioriteit wint
       → effects.py: run()             → block_ip / quarantine / notify
       → effects.py: audit()           → S3 + Aurora
```

Belangrijkste functies:

| Bestand | Functie | Wat het doet |
|---|---|---|
| `engine.py` | `normalize_event()` | Zet een EventBridge- of SQS-bericht om naar een `Finding` |
| `engine.py` | `matches()` | Checkt of een regel op een finding past |
| `engine.py` | `best_rule()` | Kiest de regel met de hoogste `priority` |
| `engine.py` | `planned_actions()` | Volgorde van acties uit `then` |
| `main.py` | `process()` | De leesbare kern: normalize → dedupe → regel → acties → audit |
| `main.py` | `_is_new()` | Dedupe: zelfde event binnen 5 minuten wordt overgeslagen |
| `effects.py` | `block_ip()` | Roept de firewall-Lambda aan |
| `effects.py` | `quarantine()` | Slaat bewijs in S3 op en tagt de instance |
| `effects.py` | `notify()` | Stuurt een SNS-melding |
| `effects.py` | `audit()` | Schrijft auditobject naar S3 en rij naar Aurora |

De HTTP-API (dezelfde app) heeft endpoints:
`/health`, `/stats`, `/rules`, `/audit/recent`, `POST /events`.

---

## 3. Regels (`soar/rules.json`)

Elke regel heeft deze velden:

```json
{
  "id": "R-110",
  "enabled": true,
  "priority": 200,
  "when": {
    "sources": ["cs2.demo", "aws.guardduty"],
    "detail_types": ["CS2 Security Finding"],
    "min_severity": "medium",
    "title_contains": ["attack", "scan", "brute", "firewall", "recon"],
    "has_source_ip": true
  },
  "then": ["block_ip", "notify"]
}
```

- `priority` — hoogste wint bij meerdere matches.
- `when.min_severity` — info < low < medium < high < critical (zie `engine.py: SEVERITY`).
- `when.title_contains` — zoekt losse woorden, hoofdletterongevoelig, in de titel.
- `when.has_source_ip` — alleen matchen als er een bron-IP is.
- `then` — acties uit `ACTIONS = ("block_ip", "quarantine", "notify")`.

De zeven regels:

| ID | Naam | Trigger | Actie |
|---|---|---|---|
| R-110 | Aanval vanaf een IP | brute/scan/attack/… met IP | block_ip + notify |
| SOAR-003 | Malware / C2 | malware/ransom/c2/… | quarantine + notify |
| R-120 | Privilege-escalatie | privilege/sudo/escalat, critical | notify |
| SOAR-005 | Platformalarm | 5xx/unhealthy/soar/dlq | notify |
| R-100 | Veel mislukte logins | login/auth/credential, high, met IP | notify |
| SOAR-001 | Hoge CPU | CloudWatch-alarm met "cpu" | notify |
| SOAR-006 | Kritieke bevinding | alles van critical | notify (vangnet) |

---

## 4. Waar pas je iets aan?

| Je wilt… | Bestand | Regel/veld |
|---|---|---|
| Een andere aanval blokkeren | `soar/rules.json` | pas `title_contains` of `min_severity` van R-110 aan |
| Blokkade-drempel verlagen | `soar/rules.json` | `when.min_severity` van R-110 |
| Quarantaine toevoegen aan een regel | `soar/rules.json` | voeg `"quarantine"` toe aan `then` |
| Blokkade-duur veranderen | `soar/app/effects.py` | `ttl_seconds` (regel ~76) of in `lambda/firewall_api.py` (DEFAULT_TTL) |
| Dedupe-venster veranderen | `soar/app/main.py` | `_is_new()` (5 minuten, regel ~55) |
| Meldingen uitzetten | `soar/rules.json` | haal `"notify"` uit `then` |
| Nieuwe regel toevoegen | `soar/rules.json` | nieuw object in `rules`, `id` uniek |
| Een regel testen | `soar/tests/test_engine.py` | voeg een test toe, run `pytest` |
| Website-gedrag aanpassen | `webapp/app.py` | endpoints `/`, `/bericht`, `/health`, `/api/berichten` |
| Firewall-logica aanpassen | `lambda/firewall_api.py` | `handler()` |
| Updates-inhoud aanpassen | `ansible/roles/*/tasks/main.yml` | pakketten / herstart / agent |
| Netwerk/IP's aanpassen | `infra/network.tf`, `infra/variables.tf` | CIDR's, subnets |
| Alarmgrenzen | `infra/observability.tf` | CloudWatch-alarmen |

Belangrijk voor de live-opdracht: **een wijziging in `soar/` of `infra/` start de Deploy-pipeline** (zie §5). Alleen een wijziging in `rules.json` of `effects.py` moet daarna nog in een nieuwe image worden gebouwd; dat is de reden dat een volledige uitrol ca. 15 min duurt.

---

## 5. Pipeline (GitHub Actions)

| Workflow | Trigger | Wat hij doet |
|---|---|---|
| `deploy.yml` (Deploy) | push naar `main` in `infra/`, `soar/`, `lambda/`, `grafana/`, `scripts/`, `bootstrap/`, of `.github/workflows/deploy.yml`; of handmatig | job **Tests en validatie** (pytest + terraform fmt/validate) → job **Terraform apply en SOAR uitrollen** (init, plan, apply, image bouwen, uitrollen) |
| `ci.yml` (CI) | pull request | dezelfde controles als Deploy, maar zonder uitrol (voor PR's) |
| `ansible-update.yml` (Wekelijkse updates) | cron ma 03:00 + handmatig | Ansible-update op beide workloadservers, tweede run moet `changed=0` zijn |
| `destroy.yml` | handmatig | omgeving afbreken |

Volgorde in Deploy:
1. **Tests en validatie** — `pytest -q` in `soar/`, `py_compile` van `webapp/app.py`, `terraform fmt -check`, `terraform init -backend=false`, `terraform validate`.
2. **Terraform apply en SOAR uitrollen** — `terraform init` (met backend), `plan`, `apply`, dan CodeBuild-image bouwen en naar ECR pushen, dan ECS-service herdeployen.

De jobnamen waar je in de demo naar wijst:
- `Tests en validatie`
- `Terraform apply en SOAR uitrollen`
- (in Ansible-workflow) `Ansible-update op de bewaakte servers`, stap `Tweede run moet changed=0 opleveren`.

---

## 6. Ansible-updates (P1-05)

- `ansible/playbooks/update.yml` — `hosts: role_workload`, `serial: 1`, roles `common` + `updates` + `observability_agent`.
- `ansible/roles/updates/tasks/main.yml` — `dnf name="*" state=latest`, herstart alleen als `needs-restarting -r` dat zegt.
- `ansible/roles/common/tasks/main.yml` — basispakketten, tijdzone UTC, chronyd, rsyslog.
- `ansible/roles/observability_agent/tasks/main.yml` — controleert of de Alloy-agent draait en of Loki bereikbaar is.
- Na afloop schrijft `update.yml` een JSON-rapport en uploadt dat naar `s3://<artifacts>/reports/`.
- De workflow faalt bewust als de tweede run een `changed>0` geeft → dat is het bewijs van idempotentie.

---

## 7. Terraform → AWS (per bestand)

| Bestand | Maakt |
|---|---|
| `network.tf` | 2 VPC's, internet gateways, NAT's, subnetten, routetabellen, Transit Gateway |
| `database.tf` | Aurora-cluster `cs2-dev-aurora` (SOAR-audit) + writer/reader |
| `web_db.tf` | Aurora-cluster `cs2-dev-web-aurora` (website) + app-code naar S3 + SSM-parameters |
| `security.tf` | Security groups (alb, soar, observability, workload, runner, aurora, lambda) |
| `soar.tf` | ECR, SQS + DLQ, DynamoDB (dedupe, blocked_ips), firewall-Lambda, ALB, ECS-taak + service, EventBridge |
| `observability.tf` | S3-buckets (loki, audit, artifacts), flow logs, CloudWatch-alarmen, SNS |
| `web.tf` | ALB target group + listener voor de website (IP-targets via TGW) |
| `runner.tf` | Runner-EC2 + de twee workloadservers |
| `iam.tf` | IAM-rollen en policies voor workload, observability, runner, ECS, Lambda |
| `codebuild.tf` | CodeBuild-project voor de SOAR-image |
| `outputs.tf` | Alle outputs die de scripts gebruiken (instance-ID's, ALB-DNS, buckets, …) |
| `variables.tf` | Alle variabelen (CIDR's, instance-types, aurora_acu, alert_email, feature flags) |
| `templates/` | user-data scripts (runner_bootstrap, observability_bootstrap, workload) |

---

## 8. Scripts (`scripts/`)

| Script | Doel |
|---|---|
| `demo_attack.sh` | Start een demo-aanval: `brute`, `scan`, `malware`, `cpu`, `event` |
| `show_audit.sh` | Toont audit: `--latest` (S3), `--db` (Aurora via API), `--follow` (CloudWatch-logs) |
| `port-forward.sh` | SSM-tunnels: `grafana` (3000), `soar` (8080), `web` (8081) |
| `send_event.py` | Stuurt een event naar EventBridge (alarm of finding) |
| `db_query.sh` | SQL op de databases (`audit` of `web`) |
| `grafana_password.sh` | Haalt het Grafana-wachtwoord uit Secrets Manager |
| `logs_overview.sh` | Overzicht van de loggroepen |
| `build_codebuild.sh` / `build_push.sh` | Bouwen van de SOAR-image |
| `destroy.sh` / `bootstrap_state.sh` / `register_runner.sh` | Levenscyclus en beheer |

---

## 9. Grafana

- `grafana/dashboards/operations.json` — Platformoperatie (Prometheus: CPU, geheugen, schijf, netwerk).
- `grafana/dashboards/soar.json` — SOAR (CloudWatch: EventsProcessed, ActionsExecuted, ProcessingErrors, SQS, ALB 5XX).
- `grafana/provisioning/dashboards/dashboards.yml` — laadt de map `dashboards/` in.
- `grafana/provisioning/datasources/datasources.yml.tftpl` — CloudWatch, Loki, Prometheus.
- Dashboards worden bij het opstarten van de observability-host uit S3 gesynchroniseerd (`infra/templates/observability_bootstrap.sh`).

---

## 10. Tests

- `soar/tests/test_engine.py` — 10 pytest-tests over de spellogica (geen AWS nodig).
  - o.a. brute force → R-110 → `["block_ip", "notify"]`, brute force zonder IP matcht niet, laag ernst matcht geen medium regel, kritiek valt terug op SOAR-006, malware → SOAR-003, hoogste prioriteit wint, correlation-id is stabiel.
- Draaien: `cd soar && pip install -r requirements.txt -r requirements-dev.txt && pytest -q`.
- In de pipeline: `pytest -q` in de job `Tests en validatie`.

---

## 11. Veelgestelde vragen

**"Hoe weet de SOAR dat een IP geblokkeerd moet worden?"**
`engine.py: best_rule()` kiest R-110 (hoogste prioriteit) omdat de finding op `title_contains` en `has_source_ip` matcht; `effects.py: block_ip()` roept de firewall-Lambda aan.

**"Wat gebeurt er met een duplicaat event?"**
`main.py: _is_new()` slaat correlation-id + tijdvenster (5 min) op in de dedupe-DynamoDB-tabel; een duplicaat binnen dat venster wordt overgeslagen.

**"Waar wordt de blokkade opgeslagen?"**
`lambda/firewall_api.py` schrijft een item in `cs2-dev-blocked-ips` (DynamoDB) met `expires_at`.

**"Waarom twee databases?"**
`infra/web_db.tf` legt uit: webdata en auditdata zijn bewust gescheiden clusters (compromis in de website mag niet bij auditdata kunnen).

**"Waarom zie ik geen publieke IP's?"**
De servers staan in private subnetten zonder publiek IP; toegang loopt via SSM. Zie `infra/network.tf` en `infra/runner.tf`.

**"Hoe bewijs je dat updates idempotent zijn?"**
De workflow `ansible-update.yml` draait het playbook twee keer en faalt als de tweede run `changed>0` geeft.

**"Waarom duurt een uitrol ~15 min?"**
Deploy bestaat uit tests → `terraform apply` (~13 min, veel AWS-resources) → CodeBuild-image bouwen → ECS-rollout.
