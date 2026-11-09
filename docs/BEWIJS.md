# Bewijsregister: waar maak je screenshots?

Dit is het register uit bijlage D van het ontwerpdocument, als checklist voor de demo.

Sla screenshots op in `bewijs/<onderdeel>/` met het nummer als bestandsnaam, bijvoorbeeld
`bewijs/2-beveiliging/2-04_blokkade-dynamodb.png`. Items met een ⚠️ hebben een voorwaarde of
zijn in deze demo bewust niet uitgevoerd.

## 0. Overzicht

| Nr. | Wat je laat zien | Waar | Geslaagd als |
|---|---|---|---|
| 0-01 | Twee VPC's met hun adresruimte | AWS-console → VPC → Your VPCs, filter Project = cs2 | Platform 10.10.0.0/16 en Workload 10.20.0.0/16, beide state available |
| 0-02 | Alle belangrijke uitvoer van de omgeving | Terminal: terraform -chdir=infra output | Output toont o.a. soar_alb_dns, web_db_endpoint, db_endpoint, audit_bucket |
| 0-03 | Laatste geslaagde uitrol | GitHub → Actions → Deploy → laatste run | Groen vinkje; stap 'Terraform apply' en 'SOAR-image bouwen en uitrollen' geslaagd |
| 0-04 | Budget en kosten | AWS-console → Billing → Budgets → cs2-dev-monthly | Budget bestaat; verbruik zichtbaar in Cost Explorer |

## 1. Netwerk

| Nr. | Wat je laat zien | Waar | Geslaagd als |
|---|---|---|---|
| 1-01 | Beide VPC's met CIDR's | VPC → Your VPCs (filter Project = cs2) | 10.10.0.0/16 en 10.20.0.0/16 |
| 1-02 | Negen subnetten, in twee zones | VPC → Subnets (filter Project = cs2) | DMZ, Applicatie en Data elk op twee AZ's; workload privé op twee AZ's en één publiek subnet |
| 1-03 | Transit Gateway met twee koppelingen | VPC → Transit gateway attachments | Twee attachments, state available, één per VPC |
| 1-04 | Routes tussen de VPC's | VPC → Transit gateway route tables | Platform-tabel stuurt 10.20.0.0/16 naar de workload-koppeling en omgekeerd |
| 1-05 | Private DNS-namen | Route 53 → Hosted zones → innovatech.internal | Records grafana, loki, prometheus, soar, db en runner bestaan; zone is Private |
| 1-06 | Uitgaande route via NAT | VPC → NAT gateways | Twee NAT gateways, state available |

## 2. Beveiliging en firewall

| Nr. | Wat je laat zien | Waar | Geslaagd als |
|---|---|---|---|
| 2-01 | Security Groups met alleen de nodige poorten | EC2 → Security groups (filter Project = cs2) | Geen inbound-regel met 0.0.0.0/0 op de servers; webservers alleen van de ALB, Ansible alleen van de runner |
| 2-02 | Servers zonder publiek IP | EC2 → Instances → kolom Public IPv4 | Lege kolom bij alle workloadservers en de observability-host |
| 2-03 | Beheer via SSM, zonder SSH vanaf internet | Systems Manager → Fleet Manager → Managed nodes | Alle EC2-instances staan online (Ping status Online) |
| 2-04 | Firewall-API blokkeert een IP | DynamoDB → Tables → cs2-dev-blocked-ips → Explore table items | Regel met ip 203.0.113.7 en de reden 'SSH brute force gedetecteerd' |
| 2-05 | Het bewijs van de blokkade-aanroep | Terminal: ./scripts/demo_attack.sh brute | FailedEntryCount 0 en 'Event geaccepteerd'; daarna regel in de tabel |
| 2-06 | Netwerkverkeer wordt vastgelegd | CloudWatch → Log groups → /aws/vpc/cs2-dev/flowlogs | Stroomregels met bron- en doelIP, poort en ACCEPT of REJECT |
| 2-07 | De API-key staat in Secrets Manager | Secrets Manager → cs2-dev/firewall-api | Geheim bestaat; waarde is niet in de code |
| ⚠️ | _Let op_ | SSM-sessielogging en secret-rotatie zijn in deze demo niet ingericht. Neem dat op als bewuste keuze, niet als vergeten. | |

## 3. Websites en load balancing

| Nr. | Wat je laat zien | Waar | Geslaagd als |
|---|---|---|---|
| 3-01 | Gastenboek met server en AZ | Browser → http://localhost:8081 na ./scripts/port-forward.sh web | Pagina toont hostnaam, instance-ID, AZ en het aantal berichten |
| 3-02 | Load balancer verdeelt over twee servers | Browser: ververs de pagina een paar keer | Hostnaam en AZ wisselen tussen de twee servers |
| 3-03 | Beide servers gezond | EC2 → Target groups → cs2-dev-web → Targets | Twee targets, beide healthy |
| 3-04 | Listener op poort 8080 stuurt naar de webservers | EC2 → Load balancers → cs2-dev-soar → Listeners | Listener HTTP:8080 met forward naar cs2-dev-web |
| 3-05 | Twee webservers in verschillende zones | EC2 → Instances (filter Role = workload), kolom AZ | Twee instances in verschillende Availability Zones |
| 3-06 | Bericht staat in de database | Terminal: ./scripts/db_query.sh web "select naam, bericht, server from berichten;" | Rijen met berichten; server-kolom toont beide servers |

## 4. Databases

| Nr. | Wat je laat zien | Waar | Geslaagd als |
|---|---|---|---|
| 4-01 | Auditcluster met writer en reader | RDS → Databases → cs2-dev-aurora | Twee instanties (cs2-dev-aurora-1 en -2), in verschillende AZ's, status Available |
| 4-02 | Webcluster met één instantie | RDS → Databases → cs2-dev-web-aurora | Eén instantie, Available; capaciteit 0 tot 2 ACU |
| 4-03 | Tabellen en kolommen | Terminal: ./scripts/db_query.sh web "\d berichten" | Kolommen id, naam, bericht, server, az, created_at |
| 4-04 | Auditrijen | Terminal: ./scripts/db_query.sh audit "select severity, count(*) from audit_events group by severity;" | Telling per ernst; minstens één rij na de demo-aanval |
| 4-05 | Versleuteling en back-up | RDS → cs2-dev-aurora → Configuration | Encryption: enabled; Backup retention: 1 dag |
| 4-06 | Geheimen van de databases | Secrets Manager → cs2-dev/db en cs2-dev/web-db | Beide geheimen bestaan; waarde niet zichtbaar in de repository |
| ⚠️ | _Let op_ | een failover (RDS → Actions → Failover) en een restore zijn in deze demo niet uitgevoerd. Dat zijn TC-04 en TC-08 in onderdeel 9. | |

## 5. Opslag en audit

| Nr. | Wat je laat zien | Waar | Geslaagd als |
|---|---|---|---|
| 5-01 | Auditbucket met versioning | S3 → cs2-dev-audit-… → Properties → Bucket Versioning | Enabled |
| 5-02 | Bewaartermijn van een jaar | S3 → cs2-dev-audit-… → Management → Lifecycle rules | Regel audit-retention met expiration 365 dagen |
| 5-03 | Auditobjecten van de SOAR | S3 → cs2-dev-audit-… → events/ | Objecten per dag, met de naam correlation_id |
| 5-04 | Inhoud van een auditobject | Terminal: ./scripts/show_audit.sh --latest | JSON met finding, rules en actions; actions bevat block_ip met status ok |
| 5-05 | Lokale Loki-opslag met bewaartermijn | S3 → cs2-dev-loki-… → Management | Regel loki-retention met expiration 37 dagen |
| 5-06 | Provisioning en rapporten | S3 → cs2-dev-artifacts-… → grafana/ en reports/ | Grafana-bestanden en JSON-rapporten van Ansible |
| ⚠️ | _Let op_ | Object Lock staat uit (enable_object_lock = false). Toon dat eerlijk in Properties en leg uit waarom. | |

## 6. Observability

| Nr. | Wat je laat zien | Waar | Geslaagd als |
|---|---|---|---|
| 6-01 | Platformdashboard met twee servers | Browser → http://localhost:3000 → Dashboards → CS2 — Platformoperatie | CPU- en geheugenlijnen voor beide webservers |
| 6-02 | SOAR-dashboard | Grafana → Dashboards → CS2 — SOAR | Verwerkte events en acties; na een demo-aanval zichtbaar |
| 6-03 | Syslog van de servers in Loki | Grafana → Explore → Loki, query {job="syslog"} | Regels met hostnaam ip-10-20-… en de tijd |
| 6-04 | Metrics van beide servers | Grafana → Explore → Prometheus, query up{job="node"} | Twee reeksen met waarde 1 |
| 6-05 | Alarmen | CloudWatch → Alarms | Alle zes CS2-alarmen zichtbaar; geen in ALARM zonder reden |
| 6-06 | Log-overzicht van de omgeving | Terminal: ./scripts/logs_overview.sh | Loggroepen met retentie en de buckets |
| ⚠️ | _Let op_ | Grafana vraagt om inloggen. Wachtwoord: ./scripts/grafana_password.sh. Het eerste dashboard is pas zichtbaar als de host klaar is (5 tot 10 minuten na de uitrol). | |

## 7. SOAR

| Nr. | Wat je laat zien | Waar | Geslaagd als |
|---|---|---|---|
| 7-01 | SOAR-service draait | ECS → Clusters → cs2-dev-soar → Services → cs2-dev-soar | Running 2, Desired 2; Deployments: rolloutState COMPLETED |
| 7-02 | Gezonde taken achter de ALB | EC2 → Target groups → cs2-dev-soar → Targets | Twee targets healthy |
| 7-03 | Events komen binnen via EventBridge | EventBridge → Rules → cs2-dev-finding-to-soar → Monitoring | Invocations > 0 na de demo-aanval |
| 7-04 | Wachtrij en dead-letter-queue | SQS → cs2-dev-soar-events en cs2-dev-soar-events-dlq → Monitoring | DLQ leeg (0 berichten); events-queue na verwerking weer op 0 |
| 7-05 | Verwerking in de logs | CloudWatch → Log groups → /aws/ecs/cs2-dev-soar | Regels 'Event … heeft regel R-110' en 'Audit opgeslagen' |
| 7-06 | Regelset en health | Terminal: curl http://localhost:8080/rules (na port-forward soar) | count 7 en de regels R-100 tot SOAR-006 |
| 7-07 | Auditrecords in Aurora via de API | Terminal: curl "http://localhost:8080/audit/recent?limit=3" | Laatste events met rules en actions |
| 7-08 | Testrapport van de regelmotor | Terminal: cd soar && pytest -q | 8 passed |
| ⚠️ | _Let op_ | de SNS-melding komt pas binnen als je de bevestigingsmail van AWS hebt goedgekeurd (status PendingConfirmation → Confirmed in SNS → Subscriptions). | |

## 8. DevOps, CI/CD en beheer

| Nr. | Wat je laat zien | Waar | Geslaagd als |
|---|---|---|---|
| 8-01 | Deploy-run succesvol | GitHub → Actions → Deploy → laatste run | Alle stappen groen, inclusief OIDC-login en Terraform apply |
| 8-02 | Samenvatting van de uitrol | GitHub → Actions → Deploy-run → Summary | Tabel met terraform-output |
| 8-03 | OIDC-login zonder vaste sleutels | AWS-console → CloudTrail → Event history → AssumeRoleWithWebIdentity | Event met userIdentity repo:dinandvanderzijden-sketch… en geen AccessDenied |
| 8-04 | Image gebouwd in de pipeline | GitHub → Actions → Deploy → stap 'SOAR-image bouwen en uitrollen' | Stap groen; ECR bevat de nieuwe tag |
| 8-05 | Image in het register | ECR → cs2-dev-soar → Images | Tags latest en de commit-SHA |
| 8-06 | Remote state met versies | S3 → cs2-dev-tfstate-… → cs2/dev/terraform.tfstate → Versions | Meerdere versies; lockfile bij apply |
| 8-07 | Destroy met bevestiging | GitHub → Actions → Destroy-run | Alleen als je de omgeving bewust hebt uitgezet: stap 'Terraform destroy' groen |
| 8-08 | Ansible-update met changed=0 | GitHub → Actions → Wekelijkse updates → run → tweede playbook-run | PLAY RECAP met changed=0 in de tweede run |
| ⚠️ | _Let op_ | de Ansible-run vereist een geregistreerde runner (./scripts/register_runner.sh). Zonder registratie blijft de run in de wachtrij staan en is dat geen bewijs. | |

## 9. Test- en validatieplan

| Nr. | Wat je laat zien | Waar | Geslaagd als |
|---|---|---|---|
| 9-01 | Testmatrix uitgevoerd | Dit document (9.2) en de map bewijs/TC-01 t/m TC-08 | Per test een screenshot en de uitkomst naast de verwachte uitkomst |
| 9-02 | Demo-aanval volledig | Terminal + DynamoDB + S3 + Aurora (zie 2-04, 5-03, 4-04) | Eén keten: event → blokkade → audit in S3 → rij in Aurora |
| 9-03 | Herhaling van dezelfde aanval | Terminal: tweede ./scripts/demo_attack.sh brute, daarna DynamoDB → cs2-dev-blocked-ips | Eén regel voor het IP (overschreven, geen duplicaat); expires_at is verlengd. LET OP: dit wijkt af van TC-03 ('verandert niets'). Benoem dat. |

## 10. Bijlagen

| Nr. | Wat je laat zien | Waar | Geslaagd als |
|---|---|---|---|
| 10-01 | Volledig bewijsregister | Dit document, bijlage D | Elke regel heeft een screenshot of de status 'niet uitgevoerd' |
