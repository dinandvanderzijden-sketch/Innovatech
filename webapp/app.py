"""CS2 website: een klein gastenboek op PostgreSQL (Aurora).

De pagina laat zien welke server antwoordt en slaat berichten op in de
database. Beide servers gebruiken dezelfde database, dus een bericht dat je
op server 1 plaatst, zie je ook terug als server 2 antwoordt.

Endpoints:
  GET  /              de pagina
  POST /bericht       bericht opslaan
  GET  /health        gezondheidscheck zonder database (voor de load balancer)
  GET  /api/berichten laatste berichten als JSON
"""

from __future__ import annotations

import os
import time
from typing import Any

import psycopg2
from flask import Flask, redirect, render_template_string, request, url_for

app = Flask(__name__)

DB_HOST = os.environ.get("DB_HOST", "")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "web")
DB_USER = os.environ.get("DB_USER", "")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")

SERVER_NAME = os.environ.get("SERVER_NAME", "onbekend")
SERVER_AZ = os.environ.get("SERVER_AZ", "onbekend")
SERVER_ID = os.environ.get("SERVER_ID", "onbekend")

SCHEMA = """
CREATE TABLE IF NOT EXISTS berichten (
    id         BIGSERIAL PRIMARY KEY,
    naam       TEXT NOT NULL,
    bericht    TEXT NOT NULL,
    server     TEXT NOT NULL,
    az         TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""

TEMPLATE = """<!doctype html>
<html lang="nl">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>CS2 gastenboek</title>
  <style>
    :root { color-scheme: dark; }
    body { font-family: system-ui, sans-serif; background: #0f172a; color: #e2e8f0;
           margin: 0; padding: 3rem 1rem; }
    .wrap { max-width: 46rem; margin: 0 auto; }
    h1 { margin: 0 0 .25rem; }
    .sub { color: #94a3b8; margin: 0 0 1.5rem; }
    .card { background: #1e293b; border: 1px solid #334155; border-radius: 12px;
            padding: 1.25rem 1.5rem; margin-bottom: 1.25rem; }
    .meta { display: grid; grid-template-columns: 11rem 1fr; gap: .35rem 1rem; margin: 0; }
    .meta dt { color: #94a3b8; }
    .meta dd { margin: 0; font-family: ui-monospace, monospace; }
    label { display: block; margin: .75rem 0 .25rem; color: #cbd5e1; }
    input, textarea { width: 100%; box-sizing: border-box; padding: .5rem .65rem;
                      border-radius: 8px; border: 1px solid #475569; background: #0f172a;
                      color: #e2e8f0; font: inherit; }
    button { margin-top: 1rem; padding: .55rem 1.1rem; border: 0; border-radius: 8px;
             background: #38bdf8; color: #082f49; font-weight: 600; cursor: pointer; }
    table { width: 100%; border-collapse: collapse; font-size: .95rem; }
    th, td { text-align: left; padding: .5rem .25rem; border-bottom: 1px solid #334155;
             vertical-align: top; }
    th { color: #94a3b8; font-weight: 600; }
    .when { color: #94a3b8; white-space: nowrap; }
    .error { border-color: #f87171; color: #fecaca; }
  </style>
</head>
<body>
  <div class="wrap">
    <h1>CS2 gastenboek</h1>
    <p class="sub">Deze pagina komt uit de database en wordt geserveerd door een van de twee webservers.</p>

    <div class="card">
      <dl class="meta">
        <dt>Server</dt><dd>{{ server }}</dd>
        <dt>Availability Zone</dt><dd>{{ az }}</dd>
        <dt>Instance-ID</dt><dd>{{ instance_id }}</dd>
        <dt>Berichten in de database</dt><dd>{{ total }}</dd>
      </dl>
    </div>

    {% if error %}
    <div class="card error">{{ error }}</div>
    {% endif %}

    <div class="card">
      <h2>Bericht plaatsen</h2>
      <form method="post" action="{{ url_for('bericht') }}">
        <label for="naam">Naam</label>
        <input id="naam" name="naam" maxlength="80" required>
        <label for="bericht">Bericht</label>
        <textarea id="bericht" name="bericht" rows="3" maxlength="500" required></textarea>
        <button type="submit">Opslaan in de database</button>
      </form>
    </div>

    <div class="card">
      <h2>Laatste berichten</h2>
      {% if berichten %}
      <table>
        <thead><tr><th>Wie</th><th>Wat</th><th>Server</th><th>Wanneer</th></tr></thead>
        <tbody>
        {% for b in berichten %}
          <tr>
            <td>{{ b.naam }}</td>
            <td>{{ b.bericht }}</td>
            <td>{{ b.server }}</td>
            <td class="when">{{ b.created_at }}</td>
          </tr>
        {% endfor %}
        </tbody>
      </table>
      {% else %}
      <p class="sub">Nog geen berichten. Plaats het eerste.</p>
      {% endif %}
    </div>
  </div>
</body>
</html>
"""


def connect() -> "psycopg2.extensions.connection":
    """Verbinding met de database, met één herhaling voor een koude Aurora."""
    last: Exception | None = None
    for attempt in range(3):
        try:
            conn = psycopg2.connect(
                host=DB_HOST,
                port=DB_PORT,
                dbname=DB_NAME,
                user=DB_USER,
                password=DB_PASSWORD,
                connect_timeout=30,
            )
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute(SCHEMA)
            return conn
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(2)
    raise RuntimeError(f"Database niet bereikbaar: {last}")


def overview() -> tuple[int, list[dict[str, Any]]]:
    with connect() as conn, conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM berichten")
        total = cur.fetchone()[0]
        cur.execute(
            """
            SELECT naam, bericht, server, to_char(created_at, 'YYYY-MM-DD HH24:MI:SS')
            FROM berichten ORDER BY id DESC LIMIT 10
            """
        )
        rows = [
            {"naam": r[0], "bericht": r[1], "server": r[2], "created_at": r[3]}
            for r in cur.fetchall()
        ]
    return total, rows


@app.get("/health")
def health() -> str:
    # Bewust zonder database: de load balancer moet de server gezond houden
    # terwijl Aurora uit slaap komt.
    return "ok\n"


@app.get("/")
def index():
    try:
        total, rows = overview()
        error = None
    except Exception as exc:  # noqa: BLE001
        total, rows, error = 0, [], str(exc)

    return render_template_string(
        TEMPLATE,
        server=SERVER_NAME,
        az=SERVER_AZ,
        instance_id=SERVER_ID,
        total=total,
        berichten=rows,
        error=error,
    )


@app.post("/bericht")
def bericht():
    naam = (request.form.get("naam") or "").strip()[:80]
    tekst = (request.form.get("bericht") or "").strip()[:500]

    if not naam or not tekst:
        return redirect(url_for("index"))

    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            "INSERT INTO berichten (naam, bericht, server, az) VALUES (%s, %s, %s, %s)",
            (naam, tekst, SERVER_NAME, SERVER_AZ),
        )

    return redirect(url_for("index"), code=303)


@app.get("/api/berichten")
def api_berichten() -> dict[str, Any]:
    total, rows = overview()
    return {"count": total, "items": rows, "server": SERVER_NAME}


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8000)
