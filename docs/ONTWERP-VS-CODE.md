# Ontwerp versus code

Dit document legt naast elk onderdeel van het ontwerp wat er in deze
repository is gebouwd, wat afwijkt en waarom. Het is bedoeld als
verantwoording voor het verslag en als eerlijke handleiding voor de demo.

Legenda:

- **Gerealiseerd** — het ontwerp is één-op-één uitgevoerd.
- **Afwijkend** — het doel is gehaald, maar met een andere techniek of
  beperking.
- **Niet gebouwd** — bewust weggelaten; staat hieronder met reden.

---

## 1. Netwerk en beveiliging

| Ontwerp | In de code | Status |
|---|---|---|
| Platform-VPC `10.10.0.0/16` | `aws_vpc.platform` + subnetten in twee AZ's | Gerealiseerd |
| Workload-VPC `10.20.0.0/16` | `aws_vpc.workload` + private en public subnet | Gerealiseerd |
| Transit Gateway als hub | `aws_ec2_transit_gateway` met twee attachments en eigen route tables | Gerealiseerd |
| Zones DMZ / App / Data / Gereserveerd | DMZ `10.10.0.0/24`+`.1.0/24`, App `10.10.16.0/24`+`.17.0/24`, Data `10.10.32.0/24`+`.33.0/24` | Afwijkend: de zoneplannen zijn /20, de subnetten zijn /24-slices zodat elke zone in twee AZ's ligt. De gereserveerde /20 is ongebruikt. |
| Private DNS `innovatech.internal` | `aws_route53_zone` met beide VPC's; records voor grafana, loki, soar, db, runner | Afwijkend: `prometheus` ontbreekt als naam; de servers gebruiken het vaste IP `10.10.16.10:9090`. |
| Deny-by-default | Security Groups met alleen de benodigde poorten | Afwijkend: NACL's staan op default. Security Groups zijn de leidende control. |
| Network Firewall in de DMZ | Niet gebouwd; de firewall-API is een simulatie | Niet gebouwd (zie §2) |
| Geen publieke SSH/RDP | SSM Session Manager; alleen poort 22 van runner naar workload | Gerealiseerd |
| Webservers | nginx + Flask op beide workloadservers, interne ALB-listener op 8080, IP-targets via de Transit Gateway | Gerealiseerd. Bewust intern: bekijken via `./scripts/port-forward.sh web`. |
| Website met database | Eigen Aurora-cluster `web` met tabel `berichten`; app schrijft en leest via Flask | Gerealiseerd. Eén instantie in plaats van Multi-AZ: kostenkeuze, net als `db_multi_az = false` in CS1. |
| Scheiding audit en webdata | Twee aparte Aurora-clusters | Gerealiseerd: de website kan niet bij de auditgegevens. |
| Alle geblokkeerde verbindingen gelogd | VPC Flow Logs (ALL) naar CloudWatch | Afwijkend: zonder Network Firewall zijn er geen firewall-logregels; flow logs laten de stromen zien. |

### Waarom geen Network Firewall?

AWS Network Firewall kost ongeveer $ 290 per maand (endpoint per AZ plus
verwerking) en voegt voor de demo weinig zichtbaars toe. Het ontwerp vraagt om
een **aantoonbare blokkade**. Die is er: de SOAR roept de firewall-API aan,
de blokkade staat in DynamoDB en de actie wordt geaudit. In productie vervang
je de Lambda door een aanroep naar Network Firewall of een WAF zonder de
SOAR-code te wijzigen (alleen `FIREWALL_API_URL`).

### Waarom geen NACL's?

NACL's zijn stateless en foutgevoelig. In deze omgeving zijn Security Groups
de primaire scheiding; dat is een bewuste, uitlegbare keuze. Voor de
eindopdracht is het verdedigbaar om NACL's als bijkomende laag toe te voegen.

---

## 2. Observability

| Ontwerp | In de code | Status |
|---|---|---|
| Grafana Alloy op de servers | Alloy verzamelt node-metrics en journald-logs | Gerealiseerd |
| Metrics naar Prometheus | `prometheus.remote_write` naar de Prometheus-container op `10.10.16.10:9090` | Afwijkend: geen AMP, zie hieronder. |
| Logs naar Loki, opslag in S3 | Loki 3.x met S3-backend; Alloy op de servers | Gerealiseerd |
| Syslog naar het platform | rsyslog op de workload → poort 6514 op de observability-host → Alloy → Loki | Gerealiseerd |
| CloudWatch voor AWS-logs | Flow Logs, ECS-logs, Lambda-logs | Gerealiseerd |
| Twee dashboards | `CS2 — Platformoperatie` en `CS2 — SOAR` | Gerealiseerd |
| Vijf logbronnen | syslog, journald, VPC Flow Logs, SOAR-logs, CloudWatch/Lambda | Afwijkend: Windows Event Log en auditd ontbreken (zie §5). |
| Zelfbewaking | Alarmen op 5XX, ongezonde taken, verwerkingsfouten, DLQ, ontbrekende data | Gerealiseerd |
| 150 dagen metrics | Prometheus bewaart 30 dagen op de eigen schijf | Afwijkend: kortere retentie dan het ontwerp; verlengen kan met een grotere EBS-volume. |
| 30 dagen logs + 90 dagen archief | Loki 30 dagen; audit staat een jaar in S3 | Afwijkend: er is geen aparte 90-daagse logarchivering; de auditbewaring is juist langer. |
| Audit minimaal een jaar | S3-levensduur 365 dagen; Aurora blijft staan | Gerealiseerd (tenzij je `audit_retention_days` verlaagt) |

### Waarom geen Amazon Managed Prometheus?

Het account waarin de demo draait, heeft een service control policy die
`aps:CreateWorkspace` blokkeert. Daarom draait Prometheus als container op
de observability-host, met dezelfde remote-write-API. Grafana, Alloy en de
dashboards zijn ongewijzigd; alleen het endpoint is anders. In een account
zonder die beperking vervang je de container door een AMP-workspace en pas je
de datasource-URL in `grafana/provisioning/datasources` aan.

### Transportversleuteling

Binnen de private VPC's gebruikt de demo HTTP (Grafana, Loki, ALB). Data in
rust is versleuteld (S3 SSE, EBS, Aurora). Voor productie is TLS op Loki en
de ALB de eerstvolgende stap; dat is bewust niet in de demo gebouwd om
certificaatbeheer en extra kosten te vermijden.

### Alerts uit het ontwerp

| Alert | Status |
|---|---|
| Veel mislukte logins (10 per bron in 5 min) | Niet als automatische detectie. De SOAR-regel R-100 reageert op een binnengekomen bevinding; er is geen metric filter op syslog. |
| SOAR-actie mislukt (>20% in 5 min) | Afwijkend: alarm op `ProcessingErrors ≥ 1` per 5 min, niet op een percentage. |
| SOAR-server niet bereikbaar (>2 min) | Gerealiseerd via `UnHealthyHostCount` (2 × 60 s). |
| Server bijna vol (CPU/disk >90%) | Afwijkend: CPU-alarm op 80%; disk zit niet in CloudWatch (Alloy levert schijfmetrics aan Prometheus, niet aan CloudWatch). |
| Geen data (5 min) | Gerealiseerd met `treat_missing_data = breaching`. |
| DLQ niet leeg | Gerealiseerd (aanvulling op het ontwerp). |

---

## 3. SOAR

| Ontwerp | In de code | Status |
|---|---|---|
| ECS Fargate, twee taken, twee zones | `aws_ecs_service` met `desired_count = 2`, taken over app-a/app-b | Gerealiseerd |
| Interne ALB | `aws_lb` internal in de DMZ-subnetten | Gerealiseerd |
| Events via EventBridge en SQS | Twee EventBridge-regels → SQS; HTTP-endpoint `/events` voor demo's | Gerealiseerd |
| Buffering en DLQ | SQS met `maxReceiveCount = 3` en DLQ | Gerealiseerd |
| Deduplicatie binnen 5 minuten | DynamoDB met een 5-minutenvenster in de sleutel | Gerealiseerd |
| Regelmotor met prioriteit | Hoogste prioriteit wint; bij gelijke stand de eerst gedefinieerde regel | Gerealiseerd |
| Drie startregels R-100/R-110/R-120 | Aanwezig, aangevuld met malware-, platform- en fallbackregels | Afwijkend: uitgebreid van drie naar zeven regels. |
| Acties: melden, audit, IP blokkeren | SNS, S3 + Aurora, firewall-API (60 min TTL) | Gerealiseerd |
| Retry met oplopende wachttijd | SQS visibility timeout 30 s → 60 s → 120 s → max 15 min | Gerealiseerd |
| Acties geïsoleerd | Elke actie heeft eigen foutafhandeling; een fout stopt de andere niet | Gerealiseerd |
| Audit append-only | S3 met versioning, unieke objectsleutel per verwerking; Aurora-tabel zonder update-pad | Afwijkend: Object Lock staat standaard uit (zie §4). |
| SOAR zonder beheerrechten | Eigen IAM-rol; alleen DynamoDB, S3, SQS, SNS, CloudWatch, Secrets Manager en `ec2:CreateTags` | Gerealiseerd |
| Quarantaine | Bewijsstuk in S3 + tag `Quarantine=true` op de instance | Afwijkend: geen automatische netwerkisolatie. Dat zou de demo onbestuurbaar maken; een analist isoleert na controle. |
| Lambda voor korte acties | Firewall-API is een Lambda in de VPC | Gerealiseerd |

### De firewall-API is publiek bereikbaar

De API Gateway heeft een regionaal endpoint en is met een API-key
beschermd. De Lambda zelf draait in de private app-subnetten. In productie
hoort hier een private API (execute-api VPC-endpoint) of een WAF voor. Dat is
bewust weggelaten om de demo betaalbaar en eenvoudig te houden.

---

## 4. Audit en continuïteit

| Ontwerp | In de code | Status |
|---|---|---|
| Aurora Serverless v2 | `min_capacity = 0`, `max_capacity = 2` | Gerealiseerd |
| Aurora Multi-AZ met standby | Twee `db.serverless`-instanties in twee AZ's, promotion tier 0 en 1 | Afwijkend: Aurora schakelt automatisch over, maar de failover is niet in de demo getest. |
| S3 met versioning | Versioning op alle drie buckets | Gerealiseerd |
| Object Lock | Alleen met `enable_object_lock = true` | Afwijkend: standaard uit, omdat de bucket dan niet verwijderd kan worden. Voor productie: aanzetten. |
| Back-ups | Aurora `backup_retention_period = 1` (point-in-time) | Afwijkend: het ontwerp vraagt RPO 15 min; PITR kan dat, maar een restore is niet getest. |
| RTO 60 min / RPO 15 min | Niet gemeten | Niet aantoonbaar in deze demo; zie §6. |
| Tweede regio | Niet gebouwd | Bewust: kosten en complexiteit; herstel = opnieuw `terraform apply`. |

---

## 5. Updates

| Ontwerp | In de code | Status |
|---|---|---|
| Ansible zonder agent | SSH naar Linux | Gerealiseerd |
| Inventory dev/prod gescheiden | Inventory op tags (`Project`, `Environment`, `Role`) | Afwijkend: één inventory met tags in plaats van aparte bestanden; filter op `cs2`/`dev`. |
| Rollen common, updates, observability_agent, soar_runtime | `common`, `updates`, `observability_agent` | Afwijkend: `soar_runtime` ontbreekt, omdat de SOAR als container via CI/CD gaat, niet via Ansible. |
| Eerst één server, dan de rest | `serial: 1` | Gerealiseerd (bij twee servers: één voor één). |
| Herstart alleen als nodig | `dnf needs-restarting -r` + `reboot` | Gerealiseerd |
| Rapport naar S3 | JSON-rapport per host naar `reports/` | Gerealiseerd |
| Tweede run met `changed=0` | Workflow draait de playbook twee keer en faalt bij wijzigingen | Gerealiseerd |
| Windows via WinRM | Niet gebouwd | Niet gebouwd: de demo is Linux-only. |
| Rollback / vaste image | Niet gebouwd | Afwijkend: `dnf` heeft geen automatische rollback; herstel gebeurt door de instance te vervangen. |

---

## 6. DevOps en CI/CD

| Ontwerp | In de code | Status |
|---|---|---|
| Terraform voor AWS-resources | `infra/` | Gerealiseerd |
| Ansible voor configuratie | `ansible/` | Gerealiseerd |
| Geen overlap | Terraform maakt geen pakketten; Ansible maakt geen AWS-resources | Gerealiseerd |
| State in S3 met locking | `infra/backend.tf`: S3 met native lockfile | Gerealiseerd. De bucket en de OIDC-rol staan in `bootstrap/` en overleven een destroy. |
| Geheimen niet in Git | Secrets Manager, SSM SecureString, GitHub Secrets | Gerealiseerd |
| PR: fmt, validate, plan, tflint, secret-scan | CI doet fmt, validate, tests en image-build | Afwijkend: `tflint`, secret-scan en `plan` staan niet in de standaard-CI. Terraform-plan staat in de optionele workflow. |
| Zelfstandige runner in AWS | EC2 met label `cs2-runner`, alleen uitgaand verkeer | Afwijkend: egress is niet beperkt tot 443/22/5986; dat zou veel AWS- en GitHub-endpoints vereisen. |
| OIDC, geen access keys | `aws_iam_openid_connect_provider` + rol in `bootstrap/` | Gerealiseerd |
| Rol met minimale rechten | `AdministratorAccess` op de OIDC-rol | Afwijkend: demo. In productie opsplitsen per workflow. |
| Image met commit-SHA | Deploy-workflow bouwt via CodeBuild en pusht `:latest`; `build_push.sh` pusht de git-SHA | Afwijkend: de standaardworkflow gebruikt `latest`, zodat een verse ECR na een apply direct werkt. |
| Image bouwen zonder Docker | `aws_codebuild_project` + `scripts/build_codebuild.sh` | Aanvulling: handig als de werkplek geen Docker heeft. |
| Rollback bij falen | ECS deployment circuit breaker | Gerealiseerd |
| Pipeline is de enige weg | Consolewijzigingen zijn mogelijk | Afwijkend: niet technisch afgedwongen (SCP/permissions boundary ontbreekt). |

---

## 7. Eisen uit het ontwerp

| Eis | Dekking | Bewijs |
|---|---|---|
| P2-01 Uitval en herstel | Deels | ALB 2 AZ, 2 SOAR-taken, Aurora 2 AZ, 2 workload-AZ's. Failover/RTO niet gemeten. |
| P2-02 Segmentatie | Ja | Twee VPC's, TGW, SG's, private subnetten. NACL's default. |
| P2-03 Database en diensten privé | Ja, met uitzondering | Aurora en ALB zijn privé; de firewall-API is publiek met API-key. |
| P2-04 Private DNS | Ja | Route 53-zone met beide VPC's. |
| P1-05 Centrale updates | Ja | Wekelijkse workflow + handmatige run; tweede run `changed=0`. |
| P2-06 Observability-stack | Ja | Grafana, Alloy, Prometheus, Loki, S3. |
| P2-07 Twee logbronnen | Ja | Syslog, journald, flow logs, SOAR-logs. |
| P2-08 SOAR automatisch en geïsoleerd | Ja | EventBridge → SQS → ECS → acties; eigen IAM. |
| P2-09 SOAR bewaakt zichzelf | Ja | Dashboard + alarmen op fouten, DLQ, 5XX en ongezonde taken. |
| P2-10 IaC | Ja | Terraform; state lokaal of optioneel S3. |
| P2-11 Pipeline met eigen runner | Ja | GitHub Actions + self-hosted runner + OIDC. |
| P2-12 DevOps-platform | Ja | Runner, workflows, rollen, SSM-sleutel. |

---

## 8. Testmatrix

| Test | Uitvoerbaar? | Hoe |
|---|---|---|
| TC-01 Alert bij hoge CPU | Ja | `./scripts/demo_attack.sh cpu` (5–10 min) of `event` (direct) |
| TC-02 SOAR-notificatie bij mislukte logins | Ja, gesimuleerd | `./scripts/send_event.py --mode finding --title "10 mislukte logins" --severity high --ip 203.0.113.7` |
| TC-03 IP blokkeren binnen 15 s | Ja | `./scripts/demo_attack.sh brute`; daarna DynamoDB controleren |
| TC-04 Uitval SOAR-taak/database | Nee, niet uitgevoerd | Kan met `aws ecs stop-task` en een Aurora-failover; niet in de demo gedaan |
| TC-05 Update over alle servers | Ja | GitHub Actions → Wekelijkse updates (tweede run `changed=0`) |
| TC-06 Eén AZ valt uit | Nee | Alleen architectureel aangetoond (twee AZ's per laag) |
| TC-07 Regel aanpassen binnen 60 s | Ja | `rules.json` wijzigen, image bouwen en uitrollen (2–4 min, niet 60 s) |
| TC-08 Restore uit back-up | Nee | Aurora PITR is ingericht (1 dag), maar niet getest |

De niet-uitgevoerde tests zijn bewust benoemd. Ze vragen een storing of een
restore en horen bij een aparte testronde; ze zijn niet nodig om de demo te
laten werken.

---

## 9. Aannames en risico's

1. **Kosten.** De omgeving is geen 24/7-productie. Zonder opruimen loopt de
   rekening op tot ongeveer $ 240 per maand.
2. **Regio.** Eén regio (`eu-central-1`). Regio-uitval is een geaccepteerd
   risico; herstel is opnieuw uitrollen.
3. **State.** Zonder S3-backend staat de state lokaal. Wie de demo vanaf een
   andere laptop doet, moet de state meenemen of de backend activeren.
4. **Secrets in state.** De SSH-sleutel en wachtwoorden staan in de
   Terraform-state. Bescherm de state alsof het een geheim is.
5. **Firewall-API.** Publiek endpoint met API-key. Voor productie: private
   API of WAF.
6. **TLS.** Intern HTTP. Voor productie: ACM-certificaat op de ALB en TLS
   tussen Alloy en Loki.
7. **Windows.** Niet gebouwd; het ontwerp noemt Windows wel. De Linux-aanpak
   is volledig uitgewerkt.
8. **Object Lock.** Staat uit om `destroy` mogelijk te maken. Voor de
   append-only eis in productie: aanzetten en de retentieperiode accepteren.
