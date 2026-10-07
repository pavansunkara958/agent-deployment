output "cluster_name" {
  value = aws_ecs_cluster.agent.name
}

output "service_name" {
  value = aws_ecs_service.agent.name
}

output "log_group" {
  value = aws_cloudwatch_log_group.agent.name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.agent.repository_url
}

output "task_role_arn" {
  description = "Hand to the customer security team for review."
  value       = aws_iam_role.task.arn
}

output "secret_arns" {
  description = "Containers only. Values are written out of band."
  value = {
    model_api_key = aws_secretsmanager_secret.model_api_key.arn
    datastore     = aws_secretsmanager_secret.datastore.arn
  }
}

output "session_table" {
  value = aws_dynamodb_table.sessions.name
}

output "egress_allowlist" {
  description = "The only hostnames reachable outside AWS."
  value       = var.allowed_egress_hosts
}
