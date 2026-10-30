#!/bin/bash
# Bootstrap van de observability-host: Grafana, Loki, syslog-ontvanger en Alloy.
# Wordt eenmalig als user-data uitgevoerd door Terraform.
set -euo pipefail

exec > >(tee -a /var/log/cs2-bootstrap.log | logger -t cs2-bootstrap -s 2>/dev/console) 2>&1

REGION="${region}"
PARAM_PREFIX="${param_prefix}"
LOKI_VERSION="3.4.2"
GRAFANA_VERSION="11.5.2"
ALLOY_VERSION="1.5.1"

dnf install -y docker rsyslog unzip curl awscli-2
systemctl enable --now docker

# ---------------------------------------------------------------- parameters
get_param() {
  aws ssm get-parameter --region "$REGION" --name "$PARAM_PREFIX/$1" \
    --query Parameter.Value --output text
}

AMP_URL="$(get_param config/amp_remote_write_url)"
LOKI_BUCKET="$(get_param config/loki_bucket)"
ARTIFACTS_BUCKET="$(get_param config/artifacts_bucket)"
GRAFANA_SECRET_ARN="$(get_param config/grafana_secret_arn)"

GRAFANA_PASSWORD="$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$GRAFANA_SECRET_ARN" --query SecretString --output text |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["admin_password"])')"

# ---------------------------------------------------------------- syslog
install -d -m 0755 /var/log/remote

cat >/etc/rsyslog.d/10-cs2-remote.conf <<'EOF'
module(load="imtcp")
input(type="imtcp" port="6514" ruleset="remote")

template(name="cs2RemoteFile" type="string" string="/var/log/remote/%HOSTNAME%.log")

ruleset(name="remote") {
  action(type="omfile" dynaFile="cs2RemoteFile" template="RSYSLOG_FileFormat")
}
EOF

systemctl enable --now rsyslog
systemctl restart rsyslog

# ---------------------------------------------------------------- Loki
install -d -m 0755 /var/loki /etc/loki /opt/cs2

cat >/etc/loki/loki.yaml <<EOF
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096
  log_level: info

common:
  path_prefix: /var/loki
  replication_factor: 1
  storage:
    s3:
      bucketnames: $LOKI_BUCKET
      region: $REGION
      s3forcepathstyle: false
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: s3
      schema: v13
      index:
        prefix: loki_index_
        period: 24h

storage_config:
  tsdb_shipper:
    active_index_directory: /var/loki/tsdb-index
    cache_location: /var/loki/tsdb-cache

limits_config:
  retention_period: ${loki_retention}h
  allow_structured_metadata: true

compactor:
  working_directory: /var/loki/compactor
  retention_enabled: true
  delete_request_store: s3
EOF

docker run -d --name loki --restart=always --network host \
  -e AWS_REGION="$REGION" \
  -v /etc/loki:/etc/loki:ro \
  -v /var/loki:/var/loki \
  "grafana/loki:$LOKI_VERSION" \
  -config.file=/etc/loki/loki.yaml

# ---------------------------------------------------------------- Grafana-provisioning
aws s3 sync "s3://$ARTIFACTS_BUCKET/grafana" /opt/cs2/grafana --delete --region "$REGION"

docker volume create grafana-data >/dev/null

docker run -d --name grafana --restart=always --network host \
  -e GF_SECURITY_ADMIN_USER=admin \
  -e GF_SECURITY_ADMIN_PASSWORD="$GRAFANA_PASSWORD" \
  -e GF_USERS_ALLOW_SIGN_UP=false \
  -e GF_AUTH_ANONYMOUS_ENABLED=false \
  -e GF_SERVER_HTTP_PORT=3000 \
  -e AWS_REGION="$REGION" \
  -v /opt/cs2/grafana/provisioning:/etc/grafana/provisioning:ro \
  -v /opt/cs2/grafana/dashboards:/var/lib/grafana/dashboards:ro \
  -v grafana-data:/var/lib/grafana \
  "grafana/grafana:$GRAFANA_VERSION"

# ---------------------------------------------------------------- Alloy (syslogbestanden -> Loki)
curl -fsSL -o /tmp/alloy.zip \
  "https://github.com/grafana/alloy/releases/download/v$ALLOY_VERSION/alloy-linux-amd64.zip"
unzip -o /tmp/alloy.zip -d /usr/local/bin
mv /usr/local/bin/alloy-linux-amd64 /usr/local/bin/alloy
chmod 0755 /usr/local/bin/alloy
install -d -m 0755 /etc/alloy

cat >/etc/alloy/config.alloy <<'EOF'
logging {
  level  = "info"
  format = "logfmt"
}

local.file_match "syslog" {
  path_targets = [{
    __path__ = "/var/log/remote/*.log",
    job      = "syslog",
  }]
}

loki.source.file "syslog" {
  targets    = local.file_match.syslog.targets
  forward_to = [loki.write.local.receiver]
}

loki.write "local" {
  endpoint {
    url = "http://127.0.0.1:3100/loki/api/v1/push"
  }
}
EOF

cat >/etc/systemd/system/alloy.service <<'EOF'
[Unit]
Description=Grafana Alloy
After=network-online.target docker.service
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

echo "Bootstrap van de observability-host is klaar."
echo "AMP remote write: $AMP_URL"
