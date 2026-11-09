# Terraform-diagram (Rover)

Dit diagram wordt gemaakt door de workflow **Terraform-diagram (Rover)**.

| Bestand | Wat het is |
|---|---|
| `terraform-rover.svg` | De Rover-graaf van de kern van de omgeving. Vector, dus inzoomen zonder kwaliteitsverlies. |
| `terraform-rover.png` | Dezelfde graaf als PNG, voor een verslag of snelle preview. |

## Wat je ziet

Rover tekent de resources uit de Terraform-code. Om het leesbaar te houden,
bevat de plan alleen de kern: VPC's, Transit Gateway, load balancers,
servers, ECS, databases, S3, SQS, EventBridge, Lambda, API Gateway,
DynamoDB, SNS en de DNS-zone. IAM-rollen, route tables, bucket-configuraties
en SSM-parameters zijn weggelaten; die staan wel in de code.

De plan wordt gemaakt tegen een **lege diagram-state**. Daardoor zijn alle
resources in het diagram groen: dat is wat de code zou aanmaken. Het is dus
een code-overzicht, niet de actuele live-state.

## Opnieuw maken

GitHub → **Actions** → **Terraform-diagram (Rover)** → **Run workflow**.
De workflow maakt de plan, filtert de kern, draait Rover en commit de SVG en PNG.
