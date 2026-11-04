#!/bin/bash
# Bootstrap van een bewaakte Linux-server: rsyslog-forwarding en Grafana Alloy
# voor metrics (naar Prometheus) en journald-logs (naar Loki).
set -euo pipefail

exec > >(tee -a /var/log/cs2-bootstrap.log | logger -t cs2-workload-bootstrap -s 2>/dev/console) 2>&1

REGION="${region}"
PARAM_PREFIX="${param_prefix}"
LOKI_URL="${loki_url}"
PROM_URL="${prometheus_url}"
ALLOY_VERSION="1.5.1"

dnf install -y rsyslog unzip awscli-2 nginx
dnf install -y stress-ng || true
systemctl enable --now rsyslog

get_param() {
  aws ssm get-parameter --region "$REGION" --name "$PARAM_PREFIX/$1" \
    --query Parameter.Value --output text
}

LOG_TARGET="$(get_param config/workload_log_target)"

HOSTNAME_SHORT="$(hostname -s)"
LOG_HOST="$(echo "$LOG_TARGET" | cut -d: -f1)"
LOG_PORT="$(echo "$LOG_TARGET" | cut -d: -f2)"

# ---------------------------------------------------------------- syslog naar de observability-host
cat >/etc/rsyslog.d/10-cs2-forward.conf <<EOF
*.* action(type="omfwd" target="$LOG_HOST" port="$LOG_PORT" protocol="tcp"
           action.resumeRetryCount="-1" queue.type="linkedList" queue.size="10000")
EOF

systemctl restart rsyslog

# ---------------------------------------------------------------- website
# De server is een webserver met een database-backed gastenboek:
#   browser -> nginx (80) -> gunicorn/Flask (127.0.0.1:8000) -> Aurora
TOKEN="$(curl -fsS -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
INSTANCE_ID="$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)"
AZ="$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)"

dnf install -y python3-pip

install -d -m 0755 /opt/cs2-web /etc/cs2-web

# Eigen venv: het pip van Amazon Linux wordt door rpm beheerd en mag je niet
# upgraden.
python3 -m venv /opt/cs2-web/venv
/opt/cs2-web/venv/bin/pip install --quiet --upgrade pip
/opt/cs2-web/venv/bin/pip install --quiet \
  "flask==3.0.3" "gunicorn==22.0.0" "psycopg2-binary==2.9.9"

WEB_DB_HOST="$(get_param config/web_db_host)"
WEB_DB_NAME="$(get_param config/web_db_name)"
WEB_DB_SECRET_ARN="$(get_param config/web_db_secret_arn)"
ARTIFACTS_BUCKET="$(get_param config/artifacts_bucket)"

SECRET_JSON="$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$WEB_DB_SECRET_ARN" --query SecretString --output text)"
WEB_DB_USER="$(echo "$SECRET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["username"])')"
WEB_DB_PASSWORD="$(echo "$SECRET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')"

cat >/etc/cs2-web/env <<EOF
DB_HOST=$WEB_DB_HOST
DB_PORT=5432
DB_NAME=$WEB_DB_NAME
DB_USER=$WEB_DB_USER
DB_PASSWORD=$WEB_DB_PASSWORD
SERVER_NAME=$(hostname)
SERVER_AZ=$AZ
SERVER_ID=$INSTANCE_ID
EOF
chmod 0600 /etc/cs2-web/env

aws s3 cp --region "$REGION" "s3://$ARTIFACTS_BUCKET/webapp/app.py" /opt/cs2-web/app.py
chmod 0644 /opt/cs2-web/app.py

cat >/etc/systemd/system/cs2-web.service <<'EOF'
[Unit]
Description=CS2 gastenboek (Flask)
After=network-online.target
Wants=network-online.target

[Service]
User=nginx
Group=nginx
WorkingDirectory=/opt/cs2-web
EnvironmentFile=/etc/cs2-web/env
ExecStart=/opt/cs2-web/venv/bin/python -m gunicorn --workers 2 --bind 127.0.0.1:8000 --timeout 60 app:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# nginx als reverse proxy. De health check praat niet met de database, zodat
# de server gezond blijft terwijl Aurora uit slaap komt.
cat >/etc/nginx/nginx.conf <<'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    access_log    /var/log/nginx/access.log;
    sendfile      on;
    keepalive_timeout 65;
    client_max_body_size 1m;

    server {
        listen 80 default_server;
        server_name _;

        location = /health {
            access_log off;
            proxy_pass http://127.0.0.1:8000/health;
        }

        location / {
            proxy_pass http://127.0.0.1:8000;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_read_timeout 60s;
        }
    }
}
EOF

systemctl daemon-reload
systemctl enable --now cs2-web
systemctl enable --now nginx

# ---------------------------------------------------------------- Alloy# ---------------------------------------------------------------- Alloy
curl -fsSL -o /tmp/alloy.zip \
  "https://github.com/grafana/alloy/releases/download/v$ALLOY_VERSION/alloy-linux-amd64.zip"
unzip -o /tmp/alloy.zip -d /usr/local/bin
mv /usr/local/bin/alloy-linux-amd64 /usr/local/bin/alloy
chmod 0755 /usr/local/bin/alloy
install -d -m 0755 /etc/alloy

cat >/etc/alloy/config.alloy <<EOF
logging {
  level  = "info"
  format = "logfmt"
}

prometheus.exporter.unix "node" {
}

prometheus.scrape "node" {
  targets         = prometheus.exporter.unix.node.targets
  forward_to      = [prometheus.relabel.instance.receiver]
  scrape_interval = "30s"
}

prometheus.relabel "instance" {
  forward_to = [prometheus.remote_write.local.receiver]

  rule {
    target_label = "instance"
    replacement  = "$HOSTNAME_SHORT"
  }

  rule {
    target_label = "job"
    replacement  = "node"
  }
}

prometheus.remote_write "local" {
  endpoint {
    url = "$PROM_URL/api/v1/write"
  }
}

loki.source.journal "journal" {
  max_age    = "12h"
  forward_to = [loki.write.loki.receiver]
  labels     = { job = "systemd-journal", instance = "$HOSTNAME_SHORT" }
}

loki.write "loki" {
  endpoint {
    url = "$LOKI_URL/loki/api/v1/push"
  }
}
EOF

cat >/etc/systemd/system/alloy.service <<'EOF'
[Unit]
Description=Grafana Alloy
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/alloy run /etc/alloy/config.alloy --server.http.listen-addr=127.0.0.1:12345
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now alloy

echo "Bootstrap van $(hostname) is klaar."
