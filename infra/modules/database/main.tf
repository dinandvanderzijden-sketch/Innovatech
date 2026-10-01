resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "MariaDB: alleen web-spoke en management"
  vpc_id      = var.vpc_id
}

# Cross-VPC verwijzen naar een Security Group werkt niet via Transit Gateway, dus CIDR-regels.
resource "aws_vpc_security_group_ingress_rule" "mysql" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.db.id
  cidr_ipv4         = each.value
  from_port         = 3306
  to_port           = 3306
  ip_protocol       = "tcp"
  description       = "MariaDB from ${each.value}"
}


resource "aws_db_instance" "this" {
  identifier     = "${var.name}-mariadb"
  engine         = "mariadb"
  engine_version = "10.11"
  instance_class = var.instance_class

  allocated_storage = 20
  storage_type      = "gp2"
  storage_encrypted = true

  db_name  = "appdb"
  username = "dbadmin"

  # AWS maakt en roteert het wachtwoord in Secrets Manager; het staat nooit in code of state.
  manage_master_user_password = true

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  backup_retention_period    = 1
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true
  apply_immediately          = true

  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-final"
  deletion_protection       = false
}
