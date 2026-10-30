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
| Docker | `docker version` |
| jq en Python 3 | `jq --version`, `python3 --version` |

Een AWS-account met voldoende rechten (de demo gaat uit van een
beheerderssessie). De geschatte kosten staan in `docs/KOSTEN.md`; reken op
ongeveer € 7 per dag zolang de omgeving aan staat.

```bash
cd cs2-platform
cp infra/terraform.tfvars.example infra/terraform.tfvars
```

Pas in `infra/terraform.tfvars` minimaal aan:

```hcl
owner       = "Jouw Naam"
github_repo = "jouw-gebruiker/cs2-platform"   # mag leeg blijven
alert_email = "jij@example.com"               # mag leeg blijven
```

> `github_repo` is nodig voor de OIDC-rol waarmee GitHub Actions in AWS mag
> inloggen. Zonder deze waarde werkt de infrastructuur wel, maar de
> deploy-workflow niet.

---

## 1. De omgeving uitrollen

```bash
terraform -chdir=infra init
terraform -chdir=infra apply
```

Terraform maakt onder andere:

- twee VPC's (`10.10.0.0/16` en `10.20.0.0/16`) met een Transit Gateway;
- een observability-host met Grafana en Loki;
- twee bewaakte Linux-servers in de Workload-VPC;
- een self-hosted GitHub Actions runner;
- een interne ALB met twee SOAR-taken op ECS Fargate;
- Aurora Serverless v2, SQS + DLQ, DynamoDB en drie S3-buckets;
- CloudWatch-alarmen, EventBridge-regels en een SNS-topic;
- een gesimuleerde firewall-API (API Gateway → Lambda → DynamoDB).

Na afloop zie je de belangrijkste waarden:

```bash
terraform -chdir=infra output
```

### De eerste keer: de SOAR-image ontbreekt nog

Bij de allereerste `apply` bestaat de ECR-repository nog leeg. De ECS-service
probeert dan te starten en blijft op **0 running tasks** staan. Dat is
verwacht. Bouw en push nu de image:

```bash
./scripts/build_push.sh
```

Het script bouwt `soar/`, pusht naar ECR, registreert een nieuwe
taakdefinitie en wacht tot de service stabiel is (2–4 minuten).

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
aws secretsmanager get-secret-value \
  --secret-id "$(terraform -chdir=infra output -raw grafana_admin_secret_arn)" \
  --query SecretString --output text | jq -r .admin_password
```

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
   De gegevens komen uit Amazon Managed Prometheus (AMP), niet uit
   CloudWatch.
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

### 3.3 SOAR end-to-end (3 min)

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
curl http://localhost:8080/audit/recent?limit=5 | jq .
./scripts/show_audit.sh --latest
```

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

### 3.4 De echte alarmflow (3–8 min, optioneel)

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

### 3.5 CI/CD (2 min)

1. Push een kleine wijziging naar `main`, bijvoorbeeld een regel in
   `soar/app/main.py` of `soar/rules.json`.
2. Open GitHub → **Actions** → **Deploy SOAR**.
3. Laat zien dat de workflow via OIDC inlogt (geen vaste AWS-sleutels).
4. Laat de nieuwe taakdefinitie en de rolling deployment in ECS zien.

```bash
aws ecs describe-services \
  --cluster cs2-dev-soar --services cs2-dev-soar \
  --query 'services[0].deployments[].[taskDefinition,rolloutState,runningCount]' \
  --output table
```

**Vertel:** de workflow gebruikt `secrets.AWS_ROLE_ARN`, de rol die Terraform
via OIDC heeft aangemaakt. Er staan geen AWS-sleutels in GitHub.

### 3.6 Updates via Ansible (2 min, optioneel)

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

### 3.7 Beveiligingspostuur (1 min)

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
| Runner verschijnt niet | Registratie mislukt | Draai `register_runner.sh` opnieuw met een verse PAT |

SSM-sessie naar een instance:

```bash
aws ssm start-session --target "$(terraform -chdir=infra output -raw observability_instance_id)"
```

---

## 6. Bewijs voor je verslag

Maak tijdens de demo screenshots van:

1. De twee VPC's en de Transit Gateway in de AWS-console.
2. De subnetten met hun CIDR's en de private route tables.
3. Het Grafana-dashboard met CPU- en geheugenlijnen van beide servers.
4. Een Loki-query met syslogregels van een workloadserver.
5. De SQS-queue met de DLQ-configuratie.
6. Het resultaat van `demo_attack.sh brute` en de DynamoDB-blokkade.
7. Een auditobject in S3 en de rij in Aurora (`/audit/recent`).
8. De GitHub Actions-run met OIDC en de nieuwe ECS-taakdefinitie.
9. De Ansible-run met `ok=`/`changed=` per host.
10. De kostenpagina of het budgetalarm.
