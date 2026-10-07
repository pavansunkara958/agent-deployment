###############################################################################
# Network — an isolated customer VPC with no general internet egress.
#
# The agent runs in PRIVATE subnets with no route to an internet gateway. It
# reaches AWS services through VPC endpoints, which keeps that traffic on the
# AWS network and off the public internet entirely.
#
# The ONE thing it cannot reach privately is the model endpoint, which lives on
# the public internet. That single exception is routed through a NAT gateway
# behind an egress allow-list, and it is the only hole in the boundary.
#
# Stating it that plainly is the point: a customer security team's first
# question is "what can this thing talk to", and the honest answer is "AWS
# services over PrivateLink, plus exactly one outbound host".
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "agent" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = "${local.name}-vpc" })
}

# --- Subnets -----------------------------------------------------------------
# Private subnets host the workload. Public subnets exist only to hold the NAT
# gateway; nothing the customer owns runs in them.

resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.agent.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name = "${local.name}-private-${count.index}"
    Tier = "private"
  })
}

resource "aws_subnet" "public" {
  count             = var.az_count
  vpc_id            = aws_vpc.agent.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 8)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  map_public_ip_on_launch = false # NAT gateways get an EIP; nothing else here

  tags = merge(local.tags, {
    Name = "${local.name}-public-${count.index}"
    Tier = "public-nat-only"
  })
}

# --- Egress path -------------------------------------------------------------
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.agent.id
  tags   = merge(local.tags, { Name = "${local.name}-igw" })
}

resource "aws_eip" "nat" {
  count  = var.single_nat_gateway ? 1 : var.az_count
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${local.name}-nat-${count.index}" })
}

resource "aws_nat_gateway" "nat" {
  count         = var.single_nat_gateway ? 1 : var.az_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.tags, { Name = "${local.name}-nat-${count.index}" })

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.agent.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(local.tags, { Name = "${local.name}-rt-public" })
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count  = var.az_count
  vpc_id = aws_vpc.agent.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat[var.single_nat_gateway ? 0 : count.index].id
  }

  tags = merge(local.tags, { Name = "${local.name}-rt-private-${count.index}" })
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# --- VPC endpoints -----------------------------------------------------------
# Secrets, logs, image pulls and the datastore never traverse the NAT gateway.
# Besides the security benefit, this is also the cheaper path: NAT data
# processing charges apply per GB and image pulls are not small.

locals {
  interface_endpoints = [
    "secretsmanager",
    "kms",
    "logs",
    "monitoring",
    "ecr.api",
    "ecr.dkr",
    "ssm",
    "ssmmessages", # required for ECS Exec break-glass
  ]
}

resource "aws_security_group" "endpoints" {
  name        = "${local.name}-vpce"
  description = "Allow HTTPS from the agent task to VPC endpoints"
  vpc_id      = aws_vpc.agent.id

  ingress {
    description     = "HTTPS from the agent task"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.agent.id]
  }

  tags = merge(local.tags, { Name = "${local.name}-vpce" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_endpoints)

  vpc_id              = aws_vpc.agent.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.name}-vpce-${each.value}" })
}

# S3 gateway endpoint — ECR layers live in S3, so image pulls need it.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.agent.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(local.tags, { Name = "${local.name}-vpce-s3" })
}

# --- Workload security group -------------------------------------------------
# No ingress at all. The agent is not a server: it polls a queue and calls out.
# An empty ingress block is deliberate and worth noticing in review.

resource "aws_security_group" "agent" {
  name        = "${local.name}-task"
  description = "Agent task: egress to VPC endpoints and the model endpoint only"
  vpc_id      = aws_vpc.agent.id

  egress {
    description = "HTTPS to AWS services and the allow-listed model endpoint"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name}-task" })
}

# Security groups cannot filter by hostname, so the actual allow-list is
# enforced at the Network Firewall below. The SG narrows to 443/TCP; the
# firewall narrows to one hostname. Two controls, two failure modes.

resource "aws_networkfirewall_rule_group" "egress_allowlist" {
  count    = var.enable_network_firewall ? 1 : 0
  capacity = 100
  name     = "${local.name}-egress-allowlist"
  type     = "STATEFUL"

  rule_group {
    rules_source {
      rules_source_list {
        generated_rules_type = "ALLOWLIST"
        target_types         = ["TLS_SNI", "HTTP_HOST"]
        targets              = var.allowed_egress_hosts
      }
    }
  }

  tags = local.tags
}

# --- Flow logs ---------------------------------------------------------------
# Required for the customer's security team to answer "what did it talk to"
# after the fact. REJECT records are the ones that matter during an incident.

resource "aws_flow_log" "vpc" {
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
  log_destination_type = "cloud-watch-logs"
  iam_role_arn         = aws_iam_role.flow_logs.arn
  traffic_type         = "ALL"
  vpc_id               = aws_vpc.agent.id

  tags = merge(local.tags, { Name = "${local.name}-flow-logs" })
}
