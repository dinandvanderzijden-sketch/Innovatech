#!/bin/bash
set -euxo pipefail

dnf install -y docker git jq unzip tar libicu
systemctl enable --now docker

# Terraform (pin de versie; >= 1.10 nodig voor S3 native locking)
TF_VERSION=1.10.5
curl -fsSL -o /tmp/terraform.zip "https://releases.hashicorp.com/terraform/$TF_VERSION/terraform_${TF_VERSION}_linux_amd64.zip"
unzip -o /tmp/terraform.zip -d /usr/local/bin
rm /tmp/terraform.zip

# GitHub Actions runner (alleen installeren; registreren gebeurt handmatig)
useradd -m -s /bin/bash runner
usermod -aG docker runner
RUNNER_VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')
mkdir -p /home/runner/actions-runner
cd /home/runner/actions-runner
curl -fsSL -o runner.tar.gz "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz"
tar xzf runner.tar.gz
rm runner.tar.gz
chown -R runner:runner /home/runner
echo "runner software installed" > /var/log/runner-ready
