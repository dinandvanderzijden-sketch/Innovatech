# Demo — van nul naar een werkende CS2-omgeving

Deze handleiding loodst je in ongeveer 12 minuten door de demo. De eerste
uitrol duurt langer (circa 15–20 minuten), omdat Terraform de VPC's, servers,
Aurora-database en containers aanmaakt.

Alles draait in AWS `eu-central-1`. Er is geen on-premises component.

---

## 0. Voorbereiding

Nodig op je laptop:

| Tool | Controle |
|---|---|
| AWS CLI v2 | `aws --version` |
| Session Manager-plugin | `session-manager-plugin` |
| Terraform ≥ 1.6 | `terraform version` |
| Docker | `docker version` (optioneel; CodeBuild kan het overnemen) |
| jq en Python 3 | `jq --version`, `python3 --version` |

Een AWS-account met voldoende rechten (de demo gaat uit van een
beheerderssessie). De geschatte kosten staan in `docs/KOSTEN.md`; reken op
ongeveer € 7 per dag zolang de omgeving aan staat.

`infra/terraform.tfvars` staat al in de repository. Pas eventueel aan:

```hcl
owner       = "Jouw Naam"
alert_email = "jij@example.com"
```

De GitHub-rol staat in `bootstrap/terraform.tfvars` (`github_repo`). Die is
nodig voor de OIDC-login van de workflows.

---

## 1. De omgeving uitrollen

Twee routes. **Route A** is de normale: alles via GitHub. **Route B** is
lokaal werken.

### Route A — via GitHub

Eenmalig lokaal, alleen als de state-bucket of de GitHub-rol nog niet bestaat
(bijvoorbeeld na een lab-reset):

```bash
./scripts/bootstrap_state.sh
```

Daarna: push naar `main`. De workflow **Deploy** draait tests, `terraform
apply`, en bouwt en pusht de SOAR-image via CodeBuild. Handmatig starten kan
met **Actions → Deploy → Run workflow**.

### Route B — lokaal

```bash
terraform -chdir=infra init
terraform -chdir=infra apply
./scripts/build_codebuild.sh
```

Terraform maakt onder andere:

- twee VPC's (`10.10.0.0/16` en `10.20.0.0/16`) met een Transit Gateway;
- een observability-host met Grafana en Loki;
- twee bewaakte Linux-servers in de Workload-VPC;
- een self-hosted GitHub Actions runner;
- een interne ALB met twee SOAR-taken op ECS Fargate;
- Aurora Serverless v2, SQS + DLQ, DynamoDB en drie S3-buckets;
- CloudWatch-alarmen, EventBridge-regels en een SNS-topic;
- een gesimuleerde firewall-API (Lambda → DynamoDB, aangeroepen via IAM).

Na afloop zie je de belangrijkste waarden:

```bash
terraform -chdir=infra output
```

### De eerste keer: de SOAR-image ontbreekt nog

Bij de allereerste `apply` is de ECR-repository leeg. De ECS-service blijft
dan op **0 running tasks** staan en de ALB geeft **503**. Dat is verwacht.
De Deploy-workflow bouwt de image automatisch; lokaal doe je dat met:

```bash
./scripts/build_codebuild.sh     # bouwt in AWS, geen Docker nodig
# of met Docker: ./scripts/build_push.sh
```

`build_codebuild.sh` zipt `soar/`, uploadt naar S3, start het
CodeBuild-project en wacht op de uitslag. Daarna krijgt de ECS-service een
nieuwe deployment (2–4 minuten).

Controleer daarna:

```bash
aws ecs describe-services \
  --cluster "$(terraform -chdir=infra output -raw ecs_cluster_name)" \
  --services "$(terraform -chdir=infra output -raw ecs_service_name)" \
  --query 'services[0].[runningCount,desiredCount,deployments[0].rolloutState]' \
  --output table
```

Verwacht: `2  2  COMPLETED`.

---

## 2. Toegang zonder publieke poorten

Er is geen bastion en er staan geen publieke IP's op de servers. Toegang gaat
via SSM Session Manager. De scripts regelen de tunnels.

### Grafana openen

```bash
./scripts/port-forward.sh grafana
```

Open <http://localhost:3000>. Gebruiker `admin`, wachtwoord:

```bash
./scripts/grafana_password.sh
```

Of met de AWS CLI (vanuit de **root** van de repository, niet vanuit
`scripts/`):

```bash
aws secretsmanager get-secret-value \
  --secret-id "$(terraform -chdir=infra output -raw grafana_admin_secret_arn)" \
  --query SecretString --output text | jq -r .admin_password
```

### De websites openen

De twee bewaakte servers draaien nginx. Ze staan niet op internet; je kijkt
ernaar via de interne load balancer en een SSM-tunnel:

```bash
./scripts/port-forward.sh web      # http://localhost:8081
```

Ververs de pagina een paar keer: de ene keer antwoordt server 1, de andere
keer server 2. De pagina toont hostnaam, instance-ID en Availability Zone,
zodat je de load balancer ziet werken. De health check van de target group
gebruikt `/health`.

### SOAR-API openen

In een tweede terminal:

```bash
./scripts/port-forward.sh soar
curl http://localhost:8080/health
curl http://localhost:8080/rules
```

---

## 3. De demo in 12 minuten

Hieronder staat een bewezen volgorde. Bij elke stap staat wat je laat zien en
welk ontwerpdeel je daarmee aantoont.

### 3.1 Netwerk en scheiding (2 min)

**Laat zien:**

```bash
aws ec2 describe-vpcs --filters Name=tag:Project,Values=cs2 \
  --query 'Vpcs[].[Tags[?Key==`Name`].Value|[0],CidrBlock,VpcId]' --output table

aws ec2 describe-transit-gateways \
  --query 'TransitGateways[].[TransitGatewayId,State,Description]' --output table

aws ec2 describe-subnets --filters Name=tag:Project,Values=cs2 \
  --query 'Subnets[].[Tags[?Key==`Name`].Value|[0],CidrBlock,AvailabilityZone]' --output table
```

**Vertel:** er zijn twee VPC's: Platform (beheer, observability, SOAR) en
Workload (de bewaakte servers). Ze zijn gekoppeld met een Transit Gateway,
niet met een VPN of peering. De workloadservers hebben geen publiek IP en
staan in private subnetten.

**Bewijs in de console:** VPC → Transit Gateway attachments → twee VPC's.

### 3.2 Observability (3 min)

Open Grafana en laat twee dashboards zien:

1. **CS2 — Platformoperatie**: CPU, geheugen, schijf en netwerk per server.
   De gegevens komen uit de Prometheus-container op de observability-host,
   niet uit CloudWatch.
2. **CS2 — SOAR**: aantal verwerkte events, acties, fouten en de SQS-wachtrij.

**Laat de logging zien** via Explore → Loki:

```logql
{job="syslog"} |= "sshd"
```

of

```logql
{job="systemd-journal", instance=~".+"}
```

De workloadservers sturen syslog naar poort 6514 op de observability-host.
Loki slaat de logs op in S3.

**Laat de netwerklogs zien:**

```bash
aws logs tail /aws/vpc/cs2-dev/flowlogs --follow
```

**Vertel:** CloudWatch bevat de AWS-native logs (VPC Flow Logs, SOAR, Lambda).
Loki bevat de OS-logs. Grafana is het ene paneel voor beide.

### 3.3 De websites met database (2 min)

Open <http://localhost:8081> (uit stap 2). Je ziet een gastenboek met:

- welke server antwoordt (hostnaam, instance-ID, Availability Zone);
- hoeveel berichten er in de database staan;
- de laatste tien berichten.

**Laat de database werken:**

1. Plaats een bericht via het formulier.
2. Ververs de pagina een paar keer: de ene keer antwoordt server A, de
   andere keer server B — het bericht blijft staan, want beide servers
   gebruiken dezelfde database.
3. Laat de JSON zien:

```bash
curl "http://localhost:8081/api/berichten" | jq .
```

**Laat de tabel zelf zien (SQL):**

```bash
./scripts/db_query.sh                    # \dt + laatste berichten
./scripts/db_query.sh web "\d berichten"  # kolommen en types
```

**Laat de database zelf zien:**

```bash
terraform -chdir=infra output web_db_endpoint

aws rds describe-db-clusters --db-cluster-identifier cs2-dev-web-aurora \
  --query 'DBClusters[0].{status:Status,db:DatabaseName,acu:ServerlessV2ScalingConfiguration}' \
  --output json

aws elbv2 describe-target-health \
  --target-group-arn "$(aws elbv2 describe-target-groups \
    --names cs2-dev-web --query 'TargetGroups[0].TargetGroupArn' --output text)" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output table
```

**Vertel:** dit is de webapplicatie uit CS1, maar nu in de cloud-only variant:
twee servers achter een interne ALB, met een eigen Aurora-database. De
database van de SOAR (audit) is bewust een apart cluster: een compromis in de
website mag nooit bij de auditgegevens kunnen. De servers hebben geen publiek
IP; de pagina is alleen via de SSM-tunnel te bereiken. De health check
(`/health`) praat niet met de database, zodat een slapende Aurora de server
niet uit de rotatie haalt.

### 3.4 SOAR end-to-end (3 min)

Stuur een brute-force-bevinding met een bron-IP:

```bash
./scripts/demo_attack.sh brute
```

De keten is:

```
EventBridge (CS2 Security Finding)
   → SQS
   → SOAR-worker (regel R-110)
   → IP blokkeren via de firewall-API
   → audit + bewijs in S3
   → SNS-melding
   → audit naar S3 + Aurora
```

Laat het resultaat zien:

```bash
curl http://localhost:8080/stats
curl "http://localhost:8080/audit/recent?limit=5" | jq .
./scripts/show_audit.sh --latest
```

> `/stats` is een teller per taak. Met twee SOAR-taken kan de ene taak nul
> tonen terwijl de andere het event verwerkte. Gebruik `/audit/recent` (uit
> Aurora) als je het totaal wilt laten zien.

**Bewijs dat de blokkade echt is uitgevoerd:**

```bash
aws dynamodb scan \
  --table-name cs2-dev-blocked-ips \
  --query 'Items[].[ip.S,reason.S,expires_at.N]' --output table
```

**Bewijs dat de melding is verstuurd:** kijk in je mailbox (als
`alert_email` is ingevuld) of in de SNS-console.

Wil je ook de quarantaine-actie laten zien, stuur dan een malware-bevinding:

```bash
./scripts/demo_attack.sh malware
```

Die regel (SOAR-003) schrijft een bewijsstuk naar S3 en tagt de instance met
`Quarantine=true`. De daadwerkelijke netwerkisolatie doet een analist.

**Vertel:** de SOAR is geen script maar een service met twee taken achter een
interne ALB. De SQS-queue heeft een dead-letter queue; mislukte berichten
gaan na drie pogingen naar de DLQ. De deduplicatie gebeurt met DynamoDB.

### 3.5 De echte alarmflow (3–8 min, optioneel)

Nu zonder nep-event: laat een server echt druk worden.

```bash
./scripts/demo_attack.sh cpu
```

De instance draait 15 minuten `stress-ng`. Het CloudWatch-alarm staat op
2 periodes van 5 minuten boven 80% CPU. Na ongeveer 5–10 minuten gaat het
alarm naar `ALARM`, EventBridge stuurt het naar SQS en de SOAR meldt het.

Volg het live:

```bash
aws cloudwatch describe-alarms --alarm-name-prefix cs2-dev-cpu \
  --query 'MetricAlarms[].[AlarmName,StateValue]' --output table

./scripts/show_audit.sh --follow
```

**Tip voor een snelle demo:** verlaag tijdelijk `period` en
`evaluation_periods` van het CPU-alarm in `infra/observability.tf` (bijvoorbeeld
60 seconden en 1 periode) en voer `terraform apply` opnieuw uit. Zet dit na de
demo terug.

### 3.6 CI/CD (2 min)

1. Push een kleine wijziging naar `main`, bijvoorbeeld een regel in
   `soar/rules.json`.
2. Open GitHub → **Actions** → **Deploy**.
3. Laat zien dat de workflow via OIDC inlogt (geen vaste AWS-sleutels),
   `terraform apply` doet en daarna de image via CodeBuild bouwt en uitrolt.
4. Laat de nieuwe taakdefinitie en de rolling deployment in ECS zien.

```bash
aws ecs describe-services \
  --cluster cs2-dev-soar --services cs2-dev-soar \
  --query 'services[0].deployments[].[taskDefinition,rolloutState,runningCount]' \
  --output table
```

**Vertel:** de workflow gebruikt de OIDC-rol uit `bootstrap/` (via
`secrets.AWS_ROLE_ARN`, of de standaardwaarde in de workflow). Er staan geen
AWS-sleutels in GitHub. De state staat in S3, zodat GitHub en je laptop
dezelfde omgeving beheren.

### 3.7 Updates via Ansible (2 min, optioneel)

Registreer eenmalig de runner:

```bash
./scripts/register_runner.sh <github-pat> <owner/repo>
```

Daarna: GitHub → **Actions** → **Wekelijkse updates** → **Run workflow**.

De workflow draait op de self-hosted runner in de Platform-VPC, logt via SSH
in op de workloadservers en werkt de pakketten bij. Laat de run-log zien met
`ok=` en `changed=` per host.

**Vertel:** de runner heeft geen publieke IP. Hij haalt werk op bij GitHub en
benadert de servers via het interne netwerk. De SSH-sleutel is door Terraform
gegenereerd en staat in SSM Parameter Store (SecureString), niet in Git.

### 3.8 Beveiligingspostuur (1 min)

```bash
# Geen publieke IP's op de servers
aws ec2 describe-instances --filters Name=tag:Project,Values=cs2 \
  --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress,PrivateIpAddress]' \
  --output table

# Security groups: alleen wat nodig is
aws ec2 describe-security-groups --filters Name=tag:Project,Values=cs2 \
  --query 'SecurityGroups[].[GroupName,IpPermissions[].IpProtocol]' --output table
```

**Vertel:** beheer gaat via SSM, niet via SSH vanaf internet. De enige
SSH-regel is van de runner naar de workloadservers. De ALB is intern. De
auditbucket is versleuteld, versiebeheerd en niet publiek.

---

## 4. Opruimen

**Via GitHub (één knop):** Actions → **Destroy** → Run workflow → typ
`DESTROY`. De state-bucket en de GitHub-rol blijven staan, zodat een volgende
Deploy meteen weer kan inloggen en uitrollen.

**Lokaal:**

```bash
./scripts/destroy.sh
```

Typ `DESTROY` om te bevestigen. Terraform verwijdert alles, inclusief de
S3-buckets (`force_destroy = true`) en de ECR-repository.

Let op:

- Staat `enable_object_lock = true`, zet die dan eerst uit en wacht de
  retentieperiode af; anders kan de bucket niet weg.
- Aurora wordt zonder slot-snapshot verwijderd (`skip_final_snapshot = true`).
- Gepushte images verdwijnen mee met de ECR-repository.

---

## 5. Als iets niet werkt

| Symptoom | Oorzaak | Oplossing |
|---|---|---|
| ECS: 0 running tasks | Image bestaat nog niet | `./scripts/build_push.sh` |
| `port-forward.sh` faalt | Session Manager-plugin ontbreekt | Installeer `session-manager-plugin` |
| Geen Grafana | Bootstrap nog bezig | Wacht 5 min; bekijk `/var/log/cs2-bootstrap.log` via SSM |
| Geen metrics in Grafana | Alloy niet gestart | `sudo systemctl status alloy` via SSM op de workloadserver |
| Geen logs in Loki | Syslog/Loki-pad geblokkeerd | Controleer SG op poort 3100 en 6514; `sudo systemctl status rsyslog` |
| SOAR verwerkt niets | Queue leeg of taak stuk | `./scripts/show_audit.sh --follow`; controleer `curl localhost:8080/health` |
| Alarm gaat niet af | 2 × 5 minuten nodig | Gebruik `demo_attack.sh event` of verlaag de periodes |
| GitHub Actions faalt op OIDC | `github_repo` verkeerd | Zet de juiste `owner/repo` en `terraform apply` opnieuw |
| OIDC geeft `AccessDenied` en blijft "Assuming role" herhalen | GitHub stuurt een sub-claim met immutable ID's (`repo:owner@123/repo@456:...`) | De trust policy accepteert beide vormen; controleer met CloudTrail `AssumeRoleWithWebIdentity` welke `sub` binnenkomt |
| Runner verschijnt niet | Registratie mislukt | Draai `register_runner.sh` opnieuw met een verse PAT |

SSM-sessie naar een instance:

```bash
aws ssm start-session --target "$(terraform -chdir=infra output -raw observability_instance_id)"
```

---

## 6. Bewijs voor je verslag

Maak tijdens de demo screenshots van:

1. De twee VPC's en de Transit Gateway in de AWS-console.
2. De website in de browser, met een bericht dat in de database staat en de server/AZ die antwoordde.
3. De subnetten met hun CIDR's en de private route tables.
4. Het Grafana-dashboard met CPU- en geheugenlijnen van beide servers.
5. Een Loki-query met syslogregels van een workloadserver.
6. De SQS-queue met de DLQ-configuratie.
7. Het resultaat van `demo_attack.sh brute` en de DynamoDB-blokkade.
8. Een auditobject in S3 en de rij in Aurora (`/audit/recent`).
9. De GitHub Actions-run met OIDC en de nieuwe ECS-taakdefinitie.
10. De Ansible-run met `ok=`/`changed=` per host.
11. De kostenpagina of het budgetalarm.
