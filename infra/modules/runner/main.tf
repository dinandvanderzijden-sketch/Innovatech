# Self-hosted GitHub Actions runner in het Hub management-subnet (REQ-07).
# Geen inkomende poorten: beheer loopt via AWS Systems Manager Session Manager.
# Registratie bij GitHub doe je eenmalig handmatig (zie README), zodat er geen token in code of state staat.

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "runner" {
  name        = "${var.name}-runner"
  description = "GitHub runner: alleen uitgaand verkeer"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "runner_all" {
  security_group_id = aws_security_group.runner.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_iam_role" "runner" {
  name = "${var.name}-runner"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "deploy" {
  role       = aws_iam_role.runner.name
  policy_arn = var.policy_arn
}

resource "aws_iam_instance_profile" "runner" {
  name = "${var.name}-runner"
  role = aws_iam_role.runner.name
}

resource "aws_instance" "runner" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.runner.id]
  iam_instance_profile   = aws_iam_instance_profile.runner.name
  user_data              = file("${path.module}/user_data.sh")

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${var.name}-runner" }

  # Een nieuwe AMI of aangepast startscript mag de geregistreerde runner niet vervangen.
  lifecycle {
    ignore_changes = [ami, user_data]
  }
}
