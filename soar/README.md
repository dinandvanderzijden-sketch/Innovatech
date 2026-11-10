# SOAR — leesgids

Deze map bevat de SOAR-container. De code is bewust in drie lagen gesplitst,
zodat je de werking in één keer kunt volgen.

## De flow in vijf stappen

```
EventBridge / POST /events
          │
          ▼
   SQS-queue  ──►  worker in main.py
                       │
                       ├─ 1. normalize_event()   event → Finding
                       ├─ 2. _is_new()           duplicaat? stop
                       ├─ 3. best_rule()         kies de regel
                       ├─ 4. effects.run()       acties uitvoeren
                       └─ 5. effects.audit()     S3 + Aurora
```

De kern staat in `process()` in `app/main.py`. Die functie leest als het ware
van boven naar beneden:

```python
finding = normalize_event(event)              # wat is er gebeurd?
if not _is_new(finding.correlation_id()):     # zagen we dit al?
    return ...
rule = best_rule(rules, finding)              # welke regel hoort hierbij?
results = effects.run(planned_actions(rule), finding, rule)
effects.audit(finding, rule, results)         # vastleggen
```

## De drie lagen

| Bestand | Rol | AWS nodig? |
|---|---|---|
| `app/engine.py` | Spellogica: `Finding`, `normalize_event`, `load_rules`, `matches`, `best_rule`, `planned_actions` | Nee |
| `app/effects.py` | Bijwerkingen: firewall-API, S3, SNS, EC2-tag, Aurora | Ja |
| `app/main.py` | HTTP-API, SQS-worker, dedupe, statistieken en CloudWatch-metrieken | Ja |
| `app/config.py` | Alle omgevingsvariabelen op één plek | Nee |
| `rules.json` | De regels; aanpassen kan zonder Python te wijzigen | Nee |

`engine.py` is bewust "puur": geen AWS en geen database. Daardoor kun je de
regels testen met `pytest` zonder een cloudomgeving.

## Een regel toevoegen

Een regel zegt: **als** aan deze voorwaarden is voldaan, **dan** deze acties.
Alles tussen `when` is optioneel; lege lijsten betekenen "maakt niet uit".

```json
{
  "id": "R-200",
  "name": "Verdacht proces op een server",
  "enabled": true,
  "priority": 90,
  "when": {
    "sources": ["cs2.demo"],
    "detail_types": ["CS2 Security Finding"],
    "min_severity": "high",
    "title_contains": ["process", "suspicious"],
    "has_source_ip": false
  },
  "then": ["quarantine", "notify"]
}
```

- **priority**: hoogste wint. Bij een gelijke stand wint de bovenste regel.
- **title_contains**: hoofdletterongevoelig; één van de woorden moet voorkomen.
- **then**: toegestaan zijn `block_ip`, `quarantine` en `notify`.
- **min_severity**: `info`, `low`, `medium`, `high` of `critical`.

Na een wijziging aan `rules.json` moet de container opnieuw gebouwd en
uitgerold worden (via de Deploy-workflow of `scripts/build_codebuild.sh`).

## Lokaal testen

```bash
cd soar
python -m pytest -q
```

De tests gebruiken alleen `app/engine.py` en `rules.json`; er is geen AWS-
account of database voor nodig.
