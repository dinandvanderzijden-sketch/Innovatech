# Demo-runbook CS2 — Medium stake 2

**Dinand van der Zijden** · 20 minuten · spreekkamer 0.19 · datum ____________ · slot ________

LO1 netwerk en scheiding · LO2 SOAR · LO3 updates, IaC en CI/CD · **oranje = live test**

## Vooraf

- [ ] ECS 2/2, Aurora *available*, vier SSM-nodes *Online*
- [ ] Tunnels open: Grafana 3000, website 8081; terminal in `cs2-platform/`
- [ ] Console-tabs: VPC's · TGW-attachments · EC2-instances · Route 53; Grafana ingelogd

## Commando's per stap

| # | Commando of actie | LO |
|---|---|---|
| 1 | **GitHub → Actions → Wekelijkse updates → Run workflow** (meteen starten)<br>*→ start nu; uitslag bij stap 13* | LO3 |
| 2 | Architectuurplaat (Design 00, figuur 1): twee VPC's, TGW, SOAR, observability | — |

### Netwerk, DNS en website — LO1

| # | Commando of actie | LO |
|---|---|---|
| 3 | Open **http://localhost:8081** en ververs 2× (tunnel: `./scripts/port-forward.sh web`)<br>*→ hostnaam en AZ wisselen; bericht blijft staan* | LO1 |
| 4 | Console → **VPC → Your VPCs**, filter *Project = cs2*<br>*→ twee VPC's: 10.10.0.0/16 en 10.20.0.0/16* | LO1 |
| 5 | Console → **VPC → Transit gateway attachments**<br>*→ twee attachments, state available* | LO1 |
| 6 | Console → **EC2 → Instances**, filter *Project = cs2*<br>*→ lege kolom Public IPv4* | LO1 |
| 7 | Console → **Route 53 → innovatech.internal** → record *db*<br>*→ waarde 10.10.32.187* | LO1 |
| 8 | **TEST 1** · **tab 1:** `aws ssm start-session --target i-01f5046dfd9fc024e`<br>**tab 2:** `aws ssm start-session --target i-0203abb6391845ddc`<br>`timeout 5 bash -c '</dev/tcp/db.innovatech.internal/5432' 2>/dev/null && echo VERBONDEN \|\| echo GEEN VERBINDING`<br>*→ tab 1: GEEN VERBINDING · tab 2: VERBONDEN* | LO1 |

### SOAR — LO2

| # | Commando of actie | LO |
|---|---|---|
| 9 | Grafana → **CS2 — SOAR**: events, acties, fouten, SQS-wachtrij | LO2 |
| 10 | **TEST 2** · `./scripts/demo_attack.sh brute`<br>*→ R-110 · block_ip + notify · IP geblokkeerd binnen 15 s* | LO2 |
| 11 | `./scripts/show_audit.sh --latest`<br>*→ auditobject met R-110* | LO2 |
| 12 | `aws dynamodb get-item --table-name cs2-dev-blocked-ips --key '{"ip":{"S":"203.0.113.7"}}' --output json`<br>*→ IP staat in de tabel* | LO2 |

### Updates, IaC en CI/CD — LO3

| # | Commando of actie | LO |
|---|---|---|
| 13 | **TEST 3** · Run uit stap 1 → job **Ansible-update** → stap *Tweede run moet changed=0 opleveren* → PLAY RECAP<br>*→ changed=0 op 10.20.22.134 en 10.20.41.231* | LO3 |
| 14 | `aws s3 ls s3://cs2-dev-artifacts-84583cee/reports/ \| sort \| tail -4`<br>*→ twee nieuwe JSON-rapporten* | LO3 |
| 15 | `terraform -chdir=infra plan -detailed-exitcode`<br>`echo "exit=$?"`<br>*→ No changes · exit=0* | LO3 |
| 16 | `git add -A`<br>`git commit -m "demo: …"`<br>`git push origin main`<br>*→ Actions → Tests en validatie groen · uitrol ca. 15 min* | LO3 |

### Afsluiten

| # | Commando of actie | LO |
|---|---|---|
| 17 | Afronden: `exit` in de SSM-sessies, Ctrl+C in de tunnels | — |

Oranje = live test (maximaal drie, één per leeruitkomst). T3 nog niet klaar bij stap 13? Laat run `43721642247` zien en kom na stap 16 terug. Bewijs per leeruitkomst staat in `TRACEABILITY.pdf`.
