# Terraform-diagrammen (Rover)

Deze map wordt gevuld door de workflow **Terraform-diagram (Rover)**. Alle
diagrammen zijn met Rover gemaakt.

## Per laag

Rover tekent standaard alle resources en alle afhankelijkheden: bij deze
omgeving zijn dat 180 knopen, en dat is onleesbaar. Daarom maakt de workflow
per laag een gerichte `terraform plan -target` en laat Rover daarop los. Elk
diagram is nog steeds een echte Rover-graaf, maar beperkt tot die laag plus de
resources die hij nodig heeft.

| Bestand | Laag |
|---|---|
| `rover/netwerk.svg` | VPC's, subnetten, Transit Gateway, NAT en Route 53 |
| `rover/beveiliging.svg` | Security Groups, firewall-API en bijbehorende Lambda/API Gateway |
| `rover/websites.svg` | Webservers, ALB, target group en de app-code in S3 |
| `rover/databases.svg` | Twee Aurora-clusters, instanties en subnet group |
| `rover/soar.svg` | ECS, ALB, SQS, EventBridge, Lambda, API Gateway, DynamoDB en SNS |
| `rover/observability.svg` | Observability-host, loggroepen, alarmen, buckets en DNS |
| `rover/opslag.svg` | Drie S3-buckets met versioning, levensduur en encryptie |
| `terraform-rover.svg` | De volledige graaf, als technisch totaalbeeld |

Elke laag heeft ook een **PNG-preview** (`rover/<laag>.png`), handig voor een
verslag of een snelle blik. De SVG is scherper bij inzoomen.

## Opnieuw maken

GitHub → **Actions** → **Terraform-diagram (Rover)** → **Run workflow**.
De workflow maakt per laag een plan, draait Rover en commit de SVG's.
