# Terraform-diagram (Rover)

Deze map wordt gevuld door de workflow **Terraform-diagram (Rover)**.

| Bestand | Wat het is |
|---|---|
| `terraform-rover.svg` | De Rover-graaf van de Terraform-plan: alle resources en hun verbindingen. Vector, dus inzoomen zonder kwaliteitsverlies. |
| `terraform-rover.png` | Dezelfde graaf als PNG, handig voor een verslag of een snelle preview. |

## Zo lees je hem

Rover toont de **afhankelijkheden** uit de plan, niet de architectuur op hoog niveau.
Elke doos is een resource of data source; de lijnen zijn `depends_on`- en
referentierelaties. Daardoor is de graaf compleet maar druk: honderden knopen.

voor het verhaal in je verslag is de architectuurfiguur in het ontwerpdocument
(onderdeel 0 en 1) leesbaarder. Gebruik de Rover-graaf als technisch bewijs:
hij laat zien dat alle resources via Terraform aan elkaar hangen en welke
resources van elkaar afhankelijk zijn.

## Opnieuw maken

GitHub → **Actions** → **Terraform-diagram (Rover)** → **Run workflow**.
De workflow maakt een plan met OIDC, draait Rover en commit de nieuwe SVG.
