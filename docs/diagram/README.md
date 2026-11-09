# Terraform-diagram (Rover)

Deze map wordt gevuld door de workflow **Terraform-diagram (Rover)**.

| Bestand | Wat het is |
|---|---|
| `terraform-overview.mmd` | Het **gelaagde overzichtsdiagram** (Mermaid): netwerk, beveiliging, websites, databases, opslag, observability, SOAR en DevOps, met de belangrijkste stromen. Gegenereerd uit `infra/*.tf` door `scripts/terraform_overview.py`. |
| `terraform-overview.md` | Hetzelfde diagram als Markdown met een resourcetelling per laag. GitHub rendert dit. |
| `terraform-rover.svg` | De volledige Rover-graaf van de plan: alle resources en hun afhankelijkheden. Vector. |
| `terraform-rover.png` | Dezelfde Rover-graaf als PNG. |

## Zo lees je hem

Er zijn twee soorten diagrammen:

- **Overzicht** (`terraform-overview`): de lagen en de belangrijkste stromen.
  Dit is het diagram voor je verslag en voor een demo.
- **Rover** (`terraform-rover`): elke resource en elke afhankelijkheid.
  Compleet, maar druk; gebruik hem als technisch bewijs.

Rover toont de **afhankelijkheden** uit de plan, niet de architectuur op hoog
niveau. Elke doos is een resource of data source; de lijnen zijn
`depends_on`- en referentierelaties.

voor het verhaal in je verslag is de architectuurfiguur in het ontwerpdocument
(onderdeel 0 en 1) leesbaarder. Gebruik de Rover-graaf als technisch bewijs:
hij laat zien dat alle resources via Terraform aan elkaar hangen en welke
resources van elkaar afhankelijk zijn.

## Opnieuw maken

GitHub → **Actions** → **Terraform-diagram (Rover)** → **Run workflow**.
De workflow maakt een plan met OIDC, draait Rover en commit de nieuwe SVG.
