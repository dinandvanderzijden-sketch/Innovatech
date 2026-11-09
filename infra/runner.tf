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
    aws_ssm_parameter.artifacts_bucket,
  ]
}

# ---------------------------------------------------------------- bewaakte servers
