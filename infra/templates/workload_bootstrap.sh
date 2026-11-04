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
# De server is een webserver: nginx toont een pagina met de eigen gegevens,
# zodat je in de browser ziet welke server antwoord gaf.
TOKEN="$(curl -fsS -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
INSTANCE_ID="$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)"
AZ="$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)"

cat >/usr/share/nginx/html/index.html <<EOF
<!doctype html>
<html lang="nl">
<head>
  <meta charset="utf-8">
  <title>CS2 webserver</title>
  <style>
    body { font-family: system-ui, sans-serif; background: #0f172a; color: #e2e8f0;
           display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
    .card { background: #1e293b; padding: 2.5rem 3rem; border-radius: 12px;
            border: 1px solid #334155; max-width: 40rem; }
    h1 { margin: 0 0 .25rem; font-size: 1.6rem; }
    p  { color: #94a3b8; margin: .25rem 0 1.5rem; }
    dl { display: grid; grid-template-columns: 10rem 1fr; gap: .4rem 1rem; margin: 0; }
    dt { color: #94a3b8; }
    dd { margin: 0; font-family: ui-monospace, monospace; }
  </style>
</head>
<body>
  <div class="card">
    <h1>CS2 webserver</h1>
    <p>Deze pagina wordt geserveerd door een bewaakte server in de Workload-VPC.</p>
    <dl>
      <dt>Hostnaam</dt><dd>$(hostname)</dd>
      <dt>Instance-ID</dt><dd>$INSTANCE_ID</dd>
      <dt>Availability Zone</dt><dd>$AZ</dd>
    </dl>
  </div>
</body>
</html>
EOF

echo "ok" >/usr/share/nginx/html/health
systemctl enable --now nginx

# ---------------------------------------------------------------- Alloy
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
