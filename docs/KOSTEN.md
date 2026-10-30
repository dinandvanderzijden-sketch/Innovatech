# Kosten

De omgeving is een demo, geen productieplatform. Dit overzicht geeft een
schatting van de kosten in `eu-central-1`, in Amerikaanse dollars, op basis
van publieke on-demand-prijzen. De werkelijke prijs hangt af van je account,
je regio en je verbruik. Controleer het definitieve bedrag met de
[AWS Pricing Calculator](https://calculator.aws/).

## Samenvatting

| Scenario | Geschatte kosten |
|---|---|
| 8 uur demo (daarna opruimen) | **$ 6 – 9** |
| Een weekend laten staan (48 uur) | **$ 30 – 40** |
| 24/7 laten draaien | **$ 270 – 300 per maand** |

De grootste vaste kostenposten zijn de Transit Gateway en de twee NAT
Gateways. Die twee samen zijn ongeveer **$ 140 per maand**, ongeacht of er
verkeer is. Daarom is opruimen belangrijk.

## Specificatie

Uitgangspunten: 730 uur per maand, twee Availability Zones, twee
workloadservers, twee SOAR-taken.

| Onderdeel | Eenheidsprijs (schatting) | Aantal | Per maand |
|---|---|---|---|
| Transit Gateway-attachment | $ 0,05/uur | 2 | $ 73,00 |
| NAT Gateway | $ 0,045/uur | 2 | $ 65,70 |
| EC2 `t3.micro` (workload) | $ 0,0104/uur | 2 | $ 15,20 |
| EC2 `t3.small` (Grafana/Loki) | $ 0,0208/uur | 1 | $ 15,20 |
| EC2 `t3.micro` (runner) | $ 0,0104/uur | 1 | $ 7,60 |
| EBS gp3 (100 GB) | $ 0,0952/GB-maand | 100 GB | $ 9,50 |
| Application Load Balancer | $ 0,0225/uur | 1 | $ 16,40 |
| ECS Fargate (0,5 vCPU + 1 GB) | $ 0,0247/uur per taak | 2 | $ 36,00 |
| Aurora Serverless v2 (2 instanties) | $ 0,12/ACU-uur | 0–2 ACU elk | $ 20 – 60,00 |
| Aurora-opslag | $ 0,10/GB-maand | ~1 GB | $ 0,10 |
| Prometheus (container op de observability-host) | inbegrepen | — | $ 0,00 |
| S3 (drie buckets) | $ 0,0245/GB-maand | < 5 GB | $ 0,15 |
| CloudWatch Logs | ~$ 0,60/GB ingest | < 2 GB | $ 0 – 1,50 |
| Secrets Manager | $ 0,40/secret | 4 | $ 1,60 |
| Route 53 private zone | $ 0,50/zone | 1 | $ 0,50 |
| SQS, SNS, Lambda, DynamoDB, API Gateway | verbruik | klein | < $ 1,00 |
| CodeBuild (image-build) | $ 0,005/minuut | ± 5 min per deploy | < $ 0,10 |
| **Totaal** | | | **± $ 285** |

Aurora Serverless v2 staat op `min_capacity = 0`. Zonder verbindingen schaalt
de database naar nul en betaal je alleen opslag. Tijdens de demo (met de SOAR
actief) draaien twee instanties van elk 2 ACU: samen ongeveer $ 0,48 per uur.
Het theoretische maximum (4 ACU, 24/7) is ongeveer $ 350 per maand; in de
praktijk blijft het ver onder dat maximum.

## Wat je tijdens de demo betaalt

| Onderdeel | 8 uur |
|---|---|
| Transit Gateway + NAT | $ 1,52 |
| EC2 + EBS | $ 0,65 |
| ALB | $ 0,18 |
| Fargate (2 taken) | $ 0,40 |
| Aurora (2 × 2 ACU) | $ 3,84 |
| Overig | < $ 1 |
| **Totaal** | **± $ 7 – 9** |

## Geld besparen

1. **Ruim op na de demo.** `./scripts/destroy.sh` verwijdert alles.
2. **Één workloadserver:** `workload_instance_count = 1`. Scheelt $ 7,60 per
   maand en een beetje EBS.
3. **Één SOAR-taak:** `soar_desired_count = 1`. Scheelt $ 18 per maand.
4. **Kleinere observability-host:** `t3.micro` in plaats van `t3.small`.
   Let op: Grafana + Loki + Alloy op één micro is krap.
5. **Aurora op 0 ACU laten:** gebeurt automatisch als er geen verbindingen
   zijn. De SOAR houdt normaal een verbinding vast zolang hij draait.
6. **Geen 24/7:** gebruik de omgeving alleen tijdens het werken aan je
   verslag en de demo.

## Budgetalarm

Terraform maakt een budget van $ 100 per maand aan zodra `alert_email` is
ingevuld. Je krijgt een melding bij 80% van dat budget. Het budget stopt
niets; het is alleen een signaal.

## Wat niet in de schatting zit

- Dataverkeer naar internet (NAT-verwerking: $ 0,045/GB).
- Kosten van je GitHub-repository (gratis voor public repo's).
- Eventueel gebruik van een bestaand domein of certificaat; de demo gebruikt
  een private Route 53-zone en HTTP binnen de VPC.
