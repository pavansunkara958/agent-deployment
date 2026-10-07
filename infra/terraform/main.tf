###############################################################################
# Secrets, data store, compute and observability.
###############################################################################

locals {
  name = "${var.customer_prefix}-support-agent"
  tags = {
    Application  = "${var.customer_prefix}-support-agent"
    Environment  = var.environment
    Owner        = var.owning_team
    DataClass    = "confidential"
    ManagedBy    = "terraform"
    CostCentre   = var.cost_centre
  }
}

# --- KMS ---------------------------------------------------------------------
# A customer-managed key, not the AWS-managed default. The difference that
# matters: the customer can revoke it. An AWS-managed key cannot be disabled,
# so "we can cut off access to our own data" is only true with a CMK.

resource "aws_kms_key" "secrets" {
  description             = "${local.name} secrets and state at rest"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountRoot"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "TaskDecryptViaSecretsManager"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.task.arn }
        Action    = ["kms:Decrypt"]
        Resource  = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.region}.amazonaws.com"
          }
        }
      },
    ]
  })

  tags = local.tags
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.secrets.key_id
}

# --- Secrets -----------------------------------------------------------------
# Values are NOT in Terraform. The resource creates an empty container; the
# value is written out of band (see docs/security-design.md). A secret in a
# .tf file is a secret in git, and a secret in state is a secret in S3.

resource "aws_secretsmanager_secret" "model_api_key" {
  name                    = "${local.name}/model-api-key"
  description             = "Model provider API key. Rotated every 90 days."
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 30

  tags = merge(local.tags, { Rotation = "90d" })
}

resource "aws_secretsmanager_secret" "datastore" {
  name                    = "${local.name}/datastore"
  description             = "Datastore connection parameters."
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 30

  tags = local.tags
}

# --- Session state -----------------------------------------------------------
resource "aws_dynamodb_table" "sessions" {
  name         = "${local.name}-sessions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "conversation_id"
  range_key    = "turn"

  attribute {
    name = "conversation_id"
    type = "S"
  }

  attribute {
    name = "turn"
    type = "N"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.secrets.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  # Conversations expire. Retaining support transcripts indefinitely is a
  # liability, not a feature, and the customer's retention policy is 90 days.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = local.tags
}

# --- Image registry ----------------------------------------------------------
resource "aws_ecr_repository" "agent" {
  name                 = local.name
  image_tag_mutability = "IMMUTABLE" # a tag cannot be repointed after release

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.secrets.arn
  }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "agent" {
  repository = aws_ecr_repository.agent.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 20 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}

# --- Compute -----------------------------------------------------------------
resource "aws_ecs_cluster" "agent" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.tags
}

resource "aws_ecs_task_definition" "agent" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64" # cheaper per vCPU-hour than x86
  }

  container_definitions = jsonencode([{
    name      = "agent"
    image     = "${aws_ecr_repository.agent.repository_url}:${var.image_tag}"
    essential = true

    # Secrets are injected by the ECS agent at task start and never appear in
    # the task definition, in Terraform state, or in `docker inspect`.
    secrets = [
      {
        name      = "MODEL_API_KEY"
        valueFrom = aws_secretsmanager_secret.model_api_key.arn
      },
      {
        name      = "DATASTORE_CONFIG"
        valueFrom = aws_secretsmanager_secret.datastore.arn
      },
    ]

    environment = [
      { name = "AWS_REGION", value = var.region },
      { name = "SESSION_TABLE", value = aws_dynamodb_table.sessions.name },
      { name = "METRIC_NAMESPACE", value = var.metric_namespace },
      { name = "MODEL_BASE_URL", value = var.model_base_url },
      { name = "DEPLOY_ENV", value = var.environment },
      { name = "LOG_LEVEL", value = "INFO" },
    ]

    readonlyRootFilesystem = true
    user                   = "10001:10001" # non-root

    linuxParameters = {
      capabilities = { drop = ["ALL"] }
    }

    # /tmp must be writable; it is a tmpfs, so nothing survives a restart.
    mountPoints = [{
      sourceVolume  = "tmp"
      containerPath = "/tmp"
      readOnly      = false
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.agent.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "agent"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "python -m app.healthcheck || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 20
    }
  }])

  volume {
    name = "tmp"
  }

  tags = local.tags
}

resource "aws_ecs_service" "agent" {
  name            = local.name
  cluster         = aws_ecs_cluster.agent.id
  task_definition = aws_ecs_task_definition.agent.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  enable_execute_command = true # break-glass shell; every session is logged

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.agent.id]
    assign_public_ip = false
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true # a failing deploy reverts itself
  }

  tags = local.tags
}

# --- Observability -----------------------------------------------------------
resource "aws_cloudwatch_log_group" "agent" {
  name              = "/aws/ecs/${local.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.secrets.arn

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/${local.name}-flow-logs"
  retention_in_days = var.log_retention_days

  tags = local.tags
}
