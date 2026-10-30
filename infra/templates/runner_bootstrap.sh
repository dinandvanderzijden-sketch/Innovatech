#!/bin/bash
# Bootstrap van de self-hosted GitHub Actions runner.
# De registratie zelf gebeurt met scripts/register_runner.sh.
set -euo pipefail

exec > >(tee -a /var/log/cs2-bootstrap.log | logger -t cs2-runner-bootstrap -s 2>/dev/console) 2>&1

REGION="${region}"
PARAM_PREFIX="${param_prefix}"

dnf install -y docker git jq unzip tar python3 python3-pip awscli-2
systemctl enable --now docker
usermod -aG docker ec2-user

# ---------------------------------------------------------------- Ansible in eigen venv
python3 -m venv /opt/ansible
/opt/ansible/bin/pip install --upgrade pip
/opt/ansible/bin/pip install "ansible-core>=2.16,<2.18" boto3 botocore
ln -sf /opt/ansible/bin/ansible /usr/local/bin/ansible
ln -sf /opt/ansible/bin/ansible-playbook /usr/local/bin/ansible-playbook
ln -sf /opt/ansible/bin/ansible-galaxy /usr/local/bin/ansible-galaxy
/opt/ansible/bin/ansible-galaxy collection install amazon.aws community.general

# ---------------------------------------------------------------- SSH-sleutel voor Ansible
install -d -m 0700 -o ec2-user -g ec2-user /home/ec2-user/.ssh
aws ssm get-parameter --region "$REGION" \
  --name "$PARAM_PREFIX/ansible/private_key" \
  --with-decryption --query Parameter.Value --output text \
  >/home/ec2-user/.ssh/ansible
chmod 0600 /home/ec2-user/.ssh/ansible
chown ec2-user:ec2-user /home/ec2-user/.ssh/ansible

# ---------------------------------------------------------------- GitHub Actions runner
RUNNER_VERSION="$(python3 - <<'PY'
import json, urllib.request
with urllib.request.urlopen("https://api.github.com/repos/actions/runner/releases/latest") as r:
    print(json.load(r)["tag_name"].lstrip("v"))
PY
)"

install -d -m 0755 /opt/actions-runner
curl -fsSL -o /tmp/runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz"
tar -xzf /tmp/runner.tar.gz -C /opt/actions-runner
chown -R ec2-user:ec2-user /opt/actions-runner

echo "Bootstrap van de runner is klaar (versie $RUNNER_VERSION)."
echo "Registreer de runner met scripts/register_runner.sh."
