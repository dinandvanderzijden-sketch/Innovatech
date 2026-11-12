# Rover-diagrammen van de huidige code

Gegenereerd met [Rover](https://github.com/im2nguyen/rover) v0.3.3 op 12-11-2026, na de deploy,
op de repository in de huidige staat (commit 88ca452, 10-11-2026). Rover heeft met de echte
AWS-login (account 491799435972) de S3-state gelezen en een plan gemaakt. Er zijn
geen stubs of aanpassingen aan de code.

| Map | Stack | Inhoud |
|---|---|---|
| `infra/index.html` | hoofdstack | 194 resources, allemaal uitgerold (0 aan te maken, 0 te wijzigen) |
| `bootstrap/index.html` | bootstrap-stack | 0 toevoegen, 2 wijzigen (alleen tags), 0 verwijderen |

Open het bestand in je browser. Dubbelklik op `index.html`, of start een server in deze map
(`python3 -m http.server`) en ga naar `http://localhost:8000/infra/`.

- **GRAPH:** het afhankelijkheidsnetwerk. Klik op een resource om alleen zijn verbindingen te zien.
- **Kleuren:** groen = wordt aangemaakt.
- **DETAILS:** de waarden van de geselecteerde resource.
- Resources staan gegroepeerd per `.tf`-bestand (network.tf, iam.tf, soar.tf, observability.tf, …).

## Status na de deploy (12-11-2026)

- `terraform plan` op `infra/`: No changes. De state bevat 198 items.
- ECS-service `cs2-dev-soar`: 2 van 2 draaiend, rollout COMPLETED.
- Target groups `cs2-dev-soar` en `cs2-dev-web`: beide targets healthy.
- `bootstrap/`: 2 wijzigingen (alleen tags, van de wijziging van 10-11). Die zijn niet toegepast,
  want de deploy-workflow past alleen `infra/` toe. Het trustbeleid is ongewijzigd.

## Wat is er veranderd ten opzichte van de vorige versie

- De firewall-API is een Lambda die direct via IAM wordt aangeroepen. Er is geen API Gateway en geen API-key.
- De vorige versies (9-11 en de eerste van 12-11) waren gemaakt met gestubde AWS-waarden, of zonder bestandsgroepen. Die zijn vervangen.
- De oude map staat in `_archief/documenten-oud/rover-9-nov`.

## Beperkingen

- Het overzicht als SVG per bestand (`overzicht-*.svg`) is niet opnieuw gemaakt; dat vraagt Graphviz.
- `versions.tf` en `backend.tf` komen niet als resource voor, omdat ze alleen provider- en backend-configuratie bevatten.

## Opnieuw genereren

```
cd cs2-platform
rover -workingDir infra -tfPath terraform -standalone -zipFileName infra-rover
rover -workingDir bootstrap -tfPath terraform -standalone -zipFileName bootstrap-rover
```

Pak de zips uit in `docs/rover/infra/` en `docs/rover/bootstrap/`.
