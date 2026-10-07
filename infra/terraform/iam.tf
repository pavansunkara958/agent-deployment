###############################################################################
# IAM — least privilege, with the conditions that make it actually least.
#
# Four roles, separated by what they are for rather than by convenience:
#
#   execution   ECS infrastructure: pull the image, write logs. Not the app.
#   task        the running agent. Reads two secrets, writes to one table.
#   deploy      CI. Can change infrastructure. Cannot read application secrets.
#   breakglass  a human, time-boxed, MFA, every action logged.
#
# The separation that matters most is execution vs task. They are frequently
# merged, and merging them means the application inherits ECR and log-group
# permissions it has no use for — permissions an attacker who reaches the
# container then also has.
#
# Every role carries a permissions boundary. A boundary is what stops a role
# that can create roles from creating one more powerful than itself, which is
# the standard privilege-escalation path through IAM.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}

# --- Permissions boundary ----------------------------------------------------
resource "aws_iam_policy" "boundary" {
  name        = "${local.name}-boundary"
  description = "Ceiling for every role this stack creates"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowedServicesOnly"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "cloudwatch:PutMetricData",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Query",
          "dynamodb:UpdateItem",
          "ecr:GetAuthorizationToken",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ssmmessages:*",
        ]
        Resource = "*"
      },
      {
        # No role under this boundary can touch IAM or alter its own limits.
        Sid    = "DenyPrivilegeEscalation"
        Effect = "Deny"
        Action = [
          "iam:*",
          "organizations:*",
          "account:*",
        ]
        Resource = "*"
      },
      {
        Sid      = "DenyOutsideRegion"
        Effect   = "Deny"
        Action   = "*"
        Resource = "*"
        Condition = {
          StringNotEquals = { "aws:RequestedRegion" = var.region }
        }
      },
    ]
  })

  tags = local.tags
}

# --- 1. Execution role -------------------------------------------------------
# ECS itself uses this to start the task. The application never assumes it.

resource "aws_iam_role" "execution" {
  name                 = "${local.name}-execution"
  permissions_boundary = aws_iam_policy.boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        # Without this, any ECS task in any account that knows the role ARN
        # could assume it. The confused-deputy fix is two conditions, not one.
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:ecs:${var.region}:${local.account_id}:*" }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "execution" {
  name = "${local.name}-execution"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PullImage"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*" # this action does not support resource scoping
      },
      {
        Sid    = "PullThisImageOnly"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = aws_ecr_repository.agent.arn
      },
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.agent.arn}:*"
      },
    ]
  })
}

# --- 2. Task role ------------------------------------------------------------
# What the agent itself can do. This is the role an attacker inherits if they
# achieve code execution in the container, so it is scoped hardest.

resource "aws_iam_role" "task" {
  name                 = "${local.name}-task"
  permissions_boundary = aws_iam_policy.boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:ecs:${var.region}:${local.account_id}:*" }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "task" {
  name = "${local.name}-task"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadNamedSecretsOnly"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          aws_secretsmanager_secret.model_api_key.arn,
          aws_secretsmanager_secret.datastore.arn,
        ]
        Condition = {
          # Only from inside the VPC. A leaked set of task credentials used
          # from anywhere else fails here, which turns credential theft into
          # a detected event rather than a successful one.
          StringEquals = { "aws:SourceVpce" = aws_vpc_endpoint.interface["secretsmanager"].id }
        }
      },
      {
        Sid      = "DecryptThoseSecrets"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.secrets.arn
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.region}.amazonaws.com"
          }
        }
      },
      {
        Sid    = "ConversationStateOnly"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Query",
          "dynamodb:UpdateItem",
        ]
        Resource = [
          aws_dynamodb_table.sessions.arn,
          "${aws_dynamodb_table.sessions.arn}/index/*",
        ]
      },
      {
        Sid      = "EmitTelemetry"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*" # does not support resource scoping
        Condition = {
          StringEquals = { "cloudwatch:namespace" = var.metric_namespace }
        }
      },
      {
        # Explicit, because the agent handles refund requests and the customer
        # is in PCI scope. Deny beats a missing Allow: it survives someone
        # later attaching a broader policy to this role by mistake.
        Sid    = "NeverTouchPaymentData"
        Effect = "Deny"
        Action = ["s3:*", "rds:*", "dynamodb:*"]
        Resource = [
          "arn:${local.partition}:s3:::${var.pci_data_bucket}",
          "arn:${local.partition}:s3:::${var.pci_data_bucket}/*",
        ]
      },
    ]
  })
}

# --- 3. Deployment role ------------------------------------------------------
# CI assumes this. It can change infrastructure and cannot read what the
# application reads — a deploy pipeline is not a reason to hold API keys.

resource "aws_iam_role" "deploy" {
  name                 = "${local.name}-deploy"
  permissions_boundary = aws_iam_policy.boundary.arn
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.ci_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # Pinned to one repo AND one branch. Without the ref condition, any
        # branch in the repo — including one from a fork PR — can deploy.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.ci_repo}:ref:refs/heads/main"
        }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "deploy" {
  name = "${local.name}-deploy"
  role = aws_iam_role.deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PushImages"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "PushToThisRepoOnly"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = aws_ecr_repository.agent.arn
      },
      {
        Sid    = "UpdateThisServiceOnly"
        Effect = "Allow"
        Action = [
          "ecs:UpdateService",
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:RegisterTaskDefinition",
        ]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:ResourceTag/Application" = local.name }
        }
      },
      {
        # Required to deploy a task definition, and the condition is what
        # keeps it safe: without PassedToService, this permission lets the
        # pipeline attach these roles to anything that accepts a role.
        Sid    = "PassTaskRoles"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          aws_iam_role.task.arn,
          aws_iam_role.execution.arn,
        ]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
      {
        Sid      = "NoSecretReads"
        Effect   = "Deny"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "*"
      },
    ]
  })
}

# --- 4. Break-glass role -----------------------------------------------------
# A named human, during an incident, with MFA and a one-hour ceiling.

resource "aws_iam_role" "breakglass" {
  name                 = "${local.name}-breakglass"
  permissions_boundary = aws_iam_policy.boundary.arn
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.breakglass_principal_arns }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        Bool          = { "aws:MultiFactorAuthPresent" = "true" }
        NumericLessThan = { "aws:MultiFactorAuthAge" = "3600" }
        # The incident id is recorded in CloudTrail with every action taken
        # under this session. Access without a reason is not access.
        StringLike = { "aws:RequestTag/IncidentId" = "INC-*" }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "breakglass" {
  name = "${local.name}-breakglass"
  role = aws_iam_role.breakglass.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Diagnose"
        Effect = "Allow"
        Action = [
          "ecs:Describe*",
          "ecs:List*",
          "logs:FilterLogEvents",
          "logs:GetLogEvents",
          "cloudwatch:GetMetric*",
          "cloudwatch:DescribeAlarms",
        ]
        Resource = "*"
      },
      {
        Sid      = "RestartTheService"
        Effect   = "Allow"
        Action   = ["ecs:UpdateService"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:ResourceTag/Application" = local.name }
        }
      },
      {
        Sid      = "ShellIntoContainer"
        Effect   = "Allow"
        Action   = ["ecs:ExecuteCommand"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:ResourceTag/Application" = local.name }
        }
      },
      {
        # Even during an incident. If an engineer needs the model API key to
        # debug, the design is wrong — and rotating it afterwards is a cost
        # nobody remembers to pay.
        Sid      = "NeverReadSecrets"
        Effect   = "Deny"
        Action   = ["secretsmanager:GetSecretValue", "kms:Decrypt"]
        Resource = "*"
      },
    ]
  })
}

# --- Flow log role -----------------------------------------------------------
resource "aws_iam_role" "flow_logs" {
  name                 = "${local.name}-flow-logs"
  permissions_boundary = aws_iam_policy.boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "${local.name}-flow-logs"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}
