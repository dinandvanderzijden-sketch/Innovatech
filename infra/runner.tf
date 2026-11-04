# ---------------------------------------------------------------- beheersleutel
resource "tls_private_key" "ansible" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ansible" {
  key_name   = "${local.name}-ansible"
  public_key = tls_private_key.ansible.public_key_openssh
}

resource "aws_ssm_parameter" "ansible_private_key" {
  name   = "${local.param_prefix}/ansible/private_key"
  type   = "SecureString"
  value  = tls_private_key.ansible.private_key_pem
  key_id = "alias/aws/ssm"
}

# ---------------------------------------------------------------- runner
resource "aws_instance" "runner" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.runner_instance_type
  subnet_id              = aws_subnet.platform["app-b"].id
  private_ip             = local.runner_private_ip
  vpc_security_group_ids = [aws_security_group.runner.id]
  iam_instance_profile   = aws_iam_instance_profile.runner.name
  key_name               = aws_key_pair.ansible.key_name

  user_data = templatefile("${path.module}/templates/runner_bootstrap.sh", {
    region       = var.aws_region
    param_prefix = local.param_prefix
  })
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${local.name}-runner"
    Role = "platform"
  }

  depends_on = [
    aws_ssm_parameter.ansible_private_key,
    aws_ssm_parameter.region,
    aws_ssm_parameter.artifacts_bucket,
  ]
}

# ---------------------------------------------------------------- bewaakte servers
resource "aws_instance" "workload" {
  count = var.workload_instance_count

  ami                    = data.aws_ami.al2023.id
  instance_type          = var.workload_instance_type
  subnet_id              = aws_subnet.workload_private[keys(local.workload_private_subnets)[count.index % length(local.workload_private_subnets)]].id
  vpc_security_group_ids = [aws_security_group.workload.id]
  iam_instance_profile   = aws_iam_instance_profile.workload.name
  key_name               = aws_key_pair.ansible.key_name

  user_data = templatefile("${path.module}/templates/workload_bootstrap.sh", {
    region         = var.aws_region
    param_prefix   = local.param_prefix
    loki_url       = "http://${local.observability_private_ip}:3100"
    prometheus_url = "http://${local.observability_private_ip}:9090"
  })
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${local.name}-workload-${count.index + 1}"
    Role = "workload"
    OS   = "linux"
  }

  depends_on = [
    aws_ssm_parameter.log_target,
    aws_ssm_parameter.prometheus_url,
    aws_ssm_parameter.region,
    aws_ssm_parameter.web_db_host,
    aws_ssm_parameter.web_db_name,
    aws_ssm_parameter.web_db_secret,
    aws_secretsmanager_secret_version.web_db,
    aws_s3_object.webapp,
    aws_iam_role_policy.workload_app,
    aws_key_pair.ansible,
  ]
}
