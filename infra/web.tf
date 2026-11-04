# ---------------------------------------------------------------- websites
# De twee bewaakte servers draaien nginx. Ze staan bewust niet op internet:
# je bekijkt de site via de interne load balancer en een SSM-tunnel
# (./scripts/port-forward.sh web).
#
# De ALB staat in de Platform-VPC, de servers in de Workload-VPC. Daarom
# gebruiken we IP-targets: die mogen via de Transit Gateway buiten de VPC
# liggen. Instance-targets zouden alleen binnen dezelfde VPC werken.

resource "aws_lb_target_group" "web" {
  name        = "${local.name}-web"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.platform.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = { Name = "${local.name}-web" }
}

resource "aws_lb_target_group_attachment" "web" {
  count = length(aws_instance.workload)

  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.workload[count.index].private_ip
  port             = 80

  # De servers staan in de Workload-VPC, de ALB in de Platform-VPC. Voor
  # IP-targets buiten de VPC is een Availability Zone verplicht; "all"
  # laat alle ALB-nodes naar de target toe.
  availability_zone = "all"
}

resource "aws_lb_listener" "web" {
  load_balancer_arn = aws_lb.soar.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}
