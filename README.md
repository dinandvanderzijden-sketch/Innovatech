# Innovatech Solutions: AWS-omgeving via GitHub (CS1-MA-NCA)

Startrepo bij het Analyse-, Ontwerp- en TCO-document. Alles wordt met Terraform uitgerold en via GitHub Actions
(self-hosted runner in de Hub) naar AWS gebracht.

```
GitHub (push/PR) --> self-hosted runner (EC2, Hub management-subnet, IAM-rol)
                        |-- infra.yml : fmt/validate/plan (PR) -> apply na goedkeuring (main)
                        '-- app.yml   : docker build -> test -> ECR -> CodeDeploy blue-green -> ECS Fargate
```

## Wat staat waar

| Pad | Requirement |
|---|---|
| `infra/modules/network` | REQ-01, 02: hub-and-spoke, Transit Gateway, NAT, NACL op data-subnets |
| `infra/modules/web` | REQ-03, 04: ECR, ALB, ECS Fargate (min 2 taken, 2 AZ's), autoscaling, blue-green (CodeDeploy) |
| `infra/modules/database` | REQ-02: RDS MariaDB Multi-AZ, privé, KMS, Secrets Manager |
| `infra/modules/runner` | REQ-07: self-hosted runner |
| `infra/modules/monitoring` | REQ-05: Prometheus + Grafana + CloudWatch-alarmen + SNS |
| `infra/bootstrap` + `backend.tf` | REQ-06: remote state in S3 met locking |
| `.github/workflows` | REQ-07, 08: pipelines voor infra en applicatie |
| `app/` | NGINX-image met `/healthz` en `/version.txt` |


## Eerste keer opzetten

Je runner staat in het netwerk dat Terraform zelf bouwt. De eerste apply doe je daarom handmatig,
daarna loopt alles via GitHub.

**Stap 1: state-bucket (AWS CloudShell of laptop met AWS-credentials)**
```bash
cd infra/bootstrap
terraform init
terraform apply -var state_bucket_name=<unieke-naam>
```

**Stap 2: hele omgeving, eenmalig handmatig (duurt ca. 15-25 minuten)**
```bash
cd ../envs/prod
terraform init
terraform apply
```
Bevestig daarna de e-mail van AWS SNS, anders krijg je geen alarmmeldingen.

**Stap 3: runner registreren bij GitHub**
1. GitHub, repo, Settings, Actions, Runners, New self-hosted runner: kopieer het registratietoken (1 uur geldig).
2. Open een shell op de runner (geen SSH nodig):
   ```bash
   aws ssm start-session --target $(terraform output -raw runner_instance_id)
   ```
3. Op de runner:
   ```bash
   sudo -iu runner
   cd actions-runner
   ./config.sh --url https://github.com/<owner>/<repo> --token <TOKEN> --labels innovatech --unattended
   exit
   cd /home/runner/actions-runner
   sudo ./svc.sh install runner && sudo ./svc.sh start
   ```
   (Was de installatie nog niet klaar? Controleer met `ls /var/log/runner-ready`.)

**Stap 4: GitHub-instellingen**
- Settings, Environments, nieuw environment `prod`, met jezelf als *Required reviewer*. Dat is de handmatige goedkeuring voor `apply` en `deploy`.
- Settings, Branches: beveilig `main` (pull request verplicht) zodat elke wijziging via een plan-preview loopt.

**Stap 5: pushen**
Push de repo naar `main`. `infra.yml` toont een plan (geen wijzigingen), en een wijziging in `app/` start `app.yml`.

## Hoe deployments verlopen

- **Infra**: PR, plan als commentaar, merge, goedkeuring in GitHub, apply.
- **App**: push in `app/`, build, test op `/healthz`, push naar ECR (tag = commit-SHA), nieuwe task definition, CodeDeploy zet een Green task set klaar, verkeer schakelt om, Blue wordt na 30 minuten afgebroken. Bij een mislukte deployment rolt CodeDeploy automatisch terug.
- Herleidbaarheid (REQ-08): image-tag en deployment-omschrijving bevatten de commit-SHA; `version.txt` op de site toont dezelfde SHA.

## Toegang tot de beheertools (zonder open poorten)

```bash
# output "grafana_port_forward" geeft het volledige commando; daarna http://localhost:3000
terraform output grafana_port_forward
```
Grafana: gebruiker `admin`, wachtwoord `admin` (je moet dit bij de eerste login wijzigen). Prometheus draait op poort 9090 op dezelfde machine.

## Testen (koppel dit aan je testplan)

| Test | Hoe |
|---|---|
| DB niet publiek bereikbaar (REQ-01/02) | Vanaf je eigen laptop: `mysql -h <rds_endpoint> -u dbadmin -p` moet timeouten. Vanaf de runner (via SSM) moet poort 3306 wel open zijn: `nc -zv <rds_endpoint> 3306`. |
| Autoscaling (REQ-04) | `docker run --rm williamyeh/hey -z 10m -c 200 http://<alb_dns_name>/`. Kijk in ECS of het aantal taken van 2 naar 4 gaat na 5 minuten boven 70% CPU, en na afloop weer terug naar 2. |
| Alerts (REQ-05) | Zelfde loadtest: de CPU-alarm mail komt via SNS. Voor 5xx: stop tijdelijk de taken of gebruik een onjuiste health check. |
| Blue-green | Wijzig `app/html/index.html`, push, en volg de deployment in de CodeDeploy-console. `version.txt` toont daarna de nieuwe SHA. |
| Failure recovery | Stop een taak handmatig: ECS start een nieuwe. Stop de runner-service: pipelines blijven pending tot hij terug is. |

## Afwijkingen t.o.v. je ontwerpdocument (neem deze op in je as-built documentatie)

1. **ALB in de web-spoke, niet in de Hub.** Een ECS-service kan zijn taken niet registreren bij een target group in een andere VPC. De Hub bevat nu NAT, runner en monitoring. Spoke 2 (10.2.0.0/16) is gereserveerd als uitbreiding.
2. **Twee subnets per laag** (ALB en RDS Multi-AZ vereisen minstens twee AZ's).
3. **Security Groups per module en CIDR-regels tussen VPC's**: verwijzen naar een SG in een andere VPC werkt niet via Transit Gateway. `publicly_accessible = false` is de RDS-variant van `associate_public_ip_address`.
4. **Beheer via SSM Session Manager** in plaats van Bastion/VPN: geen inkomende poorten (ook geen SSH).
5. **Monitoring**: YACE haalt CloudWatch-metrics naar Prometheus, want `node_exporter` werkt niet op Fargate. Alarmen met e-mail lopen via CloudWatch + SNS; de Prometheus-regels in `alerts.yml` zijn aanvullend zichtbaar in de Prometheus-UI.
6. **State locking** via S3 (`use_lockfile`), geen DynamoDB.
7. **Secrets**: de *execution role* haalt de secrets op bij het starten van de taak (niet de task role). De task role heeft daarnaast leestoegang voor de applicatie zelf.
8. **Health check** staat eerst op `/` (startimage kent geen `/healthz`); onze eigen image heeft beide.

## Bekende beperkingen / verbeterpunten (goed voor je reflectie)

- Alleen HTTP op de ALB. HTTPS vraagt een domeinnaam + ACM-certificaat.
- TLS-afdwinging op de database is niet ingesteld (controleer of `require_secure_transport` ondersteund wordt voor jouw MariaDB-versie).
- De runner heeft `AdministratorAccess` (lab-gemak). Verscherp dit tot least privilege.
- De Transit Gateway staat standaard alle spoke-naar-spoke routes toe; de afscherming zit in Security Groups en NACL. Aparte TGW-route tables zijn een mogelijke verbetering.

## Kosten en opruimen

Transit Gateway-attachments, NAT Gateway, ALB en Multi-AZ RDS kosten ook als niemand de site bezoekt.
Controleer je verwachte kosten in de AWS Pricing Calculator. Tijdens het bouwen kun je `db_multi_az = false` zetten.
Opruimen: `terraform destroy` in `infra/envs/prod` (de state-bucket in bootstrap heeft `prevent_destroy`).
