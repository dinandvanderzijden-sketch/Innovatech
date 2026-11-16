# Traceability — demo CS2 (Medium stake 2)

**Dinand van der Zijden** · stapnummers verwijzen naar de commando's in `DEMO-RUNBOOK.pdf` (1–17) ·
§8.2 en §8.3 komen uit het Test- en validatieplan (Design Document 8)

| Requirement | LO | Stap | Type | Verwacht resultaat | Bewijs in portfolio |
|---|---|---|---|---|---|
| **P2-02 — segmentatie** | LO1 | 4, 5, 6 | Werkend onderdeel | Twee VPC's, Transit Gateway, geen publieke IP's op de servers | Testplan §8.3 (P2-02, P2-03); Design 01 |
| **P2-04 — private DNS** | LO1 | 7 | Werkend onderdeel | `db.innovatech.internal` lost op naar `10.10.32.187` | Testplan §8.3 (P2-04); Design 01 |
| **P2-03 — private database** | LO1 | 8 | **Test T1 (negatief)** | Workload krijgt geen verbinding op 5432; runner wel | Testplan §8.3 (P2-03); Design 01/04 |
| **P2-08 — SOAR-monitoring** | LO2 | 9 | Werkend onderdeel | Dashboard toont verwerkte events, acties en fouten | Testplan §8.3 (P2-08, P2-09); dashboard **CS2 — SOAR**; Design 06 |
| **P2-06 — event-driven SOAR** | LO2 | 10, 11, 12 | **Test T2 (TC-03)** | Brute-force → R-110 → IP-blokkade binnen 15 s + notificatie + audit | Testplan §8.2 (TC-03); SOAR-playbook |
| **P1-05 — centrale updates** | LO3 | 1, 13, 14 | **Test T3 (TC-05)** | Tweede Ansible-run `changed=0` op beide hosts; rapport in S3 | Testplan §8.2 (TC-05); workflow-run `43721642247` |
| **P2-10 — infrastructuur als code** | LO3 | 15 | Werkend onderdeel | `terraform plan` geeft `No changes` | Testplan §8.3 (P2-10, P2-11, P2-12); Design 07 |
| **P2-11 — CI/CD op eigen runner** | LO3 | 16 | Werkend onderdeel | Wijziging (docentopdracht) via Git; tests-job groen op de runner; uitrol gestart | Testplan §8.3 (P2-11); deploy-run `43715402814`; GitHub Actions |
| **P2-12 — DevOps-platform** | LO3 | 16 | Werkend onderdeel | Commit, pipeline en taakdefinitie herleidbaar | Testplan §8.3 (P2-12); GitHub-geschiedenis; Design 07 |
| **P2-07 — logbronnen en alerting** | LO2 | 9 | Werkend onderdeel | CloudWatch, Loki en Prometheus als bron in Grafana | Testplan §8.3 (P2-06, P2-07); Design 05/06 |
| **P2-01 — design-for-failure** | LO2 (optioneel) | — | Niet in demo | — | Testplan §8.2 (TC-04, deel A); Design 03/04 |
| **LO4 — beheer en compliance** | LO4 | — | Niet in demo | — | Design 06/08 |

## Niet in de demo

TC-01, TC-02, TC-04, TC-06, TC-07 en TC-08 (testplan §8.2) zijn geen live test: maximaal drie. TC-07 duurt in de huidige pipeline ca. 16 min; de groene deploy-run staat als bewijs. TC-06 en TC-08 zijn nog niet uitgevoerd.

## Bekende afwijkingen

D-01: `demo_attack.sh event` werkt niet, daarom gebruikt de demo `brute`. D-02: een tweede event met hetzelfde IP overschrijft het record. P2-07: nog geen metric filter op syslog.
