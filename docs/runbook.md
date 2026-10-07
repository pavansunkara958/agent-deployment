# Operational Runbook

**Audience:** Cascade platform engineering on-call. Assumes no prior knowledge
of this system beyond AWS and ECS.

**Access:** `cascade-support-agent-breakglass` — MFA, 1 hour maximum, and an
incident id, which is recorded in CloudTrail against every action you take.

```bash
aws sts assume-role \
  --role-arn arn:aws:iam::<acct>:role/cascade-support-agent-breakglass \
  --role-session-name "$USER-INC-1234" \
  --tags Key=IncidentId,Value=INC-1234 \
  --serial-number <your-mfa-arn> --token-code <code>
```

---

## 0 · First 60 seconds

```bash
export CLUSTER=cascade-support-agent SERVICE=cascade-support-agent
export LOG=/aws/ecs/cascade-support-agent REGION=eu-west-2

# Is it running?
aws ecs describe-services --cluster $CLUSTER --services $SERVICE --region $REGION \
  --query 'services[0].{status:status,running:runningCount,desired:desiredCount,deployments:length(deployments)}'

# What is it saying?
aws logs tail $LOG --since 15m --region $REGION --filter-pattern '{ $.level = "ERROR" }'

# What changed?
aws ecs describe-services --cluster $CLUSTER --services $SERVICE --region $REGION \
  --query 'services[0].events[:5].[createdAt,message]' --output table
```

`deployments > 1` means a deploy is in progress or stuck — check that before
anything else, because it is the most common cause and the easiest to undo.

---

## 1 · Deploy

Normal path is CI. This is the manual procedure for when CI is unavailable.

```bash
cd infra/terraform
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan        # READ IT. Any IAM or SG change is a stop.
terraform apply tfplan

python ../../scripts/verify_deployment.py --env aws --prefix cascade
```

**Rules:**

1. Never `terraform apply` without reading the plan. An unexpected IAM or
   security group diff means someone changed something in the console, and
   applying will silently revert or compound it.
2. Image tags are git shas. **Never `latest`** — Terraform rejects it.
3. The verifier must pass before you consider the deploy done. A green ECS
   service with a failed control is not a successful deployment.

**A failing deploy rolls itself back.** The circuit breaker is enabled; you
will see the service return to the previous task definition without
intervention. Confirm rather than assume:

```bash
aws ecs describe-services --cluster $CLUSTER --services $SERVICE --region $REGION \
  --query 'services[0].deployments[].{status:status,taskDef:taskDefinition,rollout:rolloutState}'
```

---

## 2 · Rollback

```bash
# Previous task definition revisions
aws ecs list-task-definitions --family-prefix cascade-support-agent \
  --sort DESC --max-items 5 --region $REGION

aws ecs update-service --cluster $CLUSTER --service $SERVICE \
  --task-definition cascade-support-agent:<previous-revision> \
  --region $REGION

aws ecs wait services-stable --cluster $CLUSTER --services $SERVICE --region $REGION
```

**Target: under 5 minutes.** Then raise a Terraform change to match — a
rollback done only in the API is drift, and the next `terraform apply` will
undo your fix at the worst possible moment.

**What a rollback does not undo:** anything already written to DynamoDB, and
any refund already issued. Reverting code does not revert side effects. If the
incident involved incorrect refunds, list them before rolling back:

```bash
aws logs filter-log-events --log-group-name $LOG --region $REGION \
  --start-time $(( ($(date +%s) - 7200) * 1000 )) \
  --filter-pattern '{ $.event = "tool_call" && $.tool = "issue_refund" }'
```

---

## 3 · Symptoms

### Tasks will not start

```bash
TASK=$(aws ecs list-tasks --cluster $CLUSTER --desired-status STOPPED \
  --region $REGION --query 'taskArns[0]' --output text)
aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK --region $REGION \
  --query 'tasks[0].{stopped:stoppedReason,containers:containers[].reason}'
```

| `stoppedReason` contains | Cause | Fix |
|---|---|---|
| `ResourceInitializationError … secret` | secret empty or task role cannot read it | §4 |
| `CannotPullContainerError` | ECR endpoint or image tag | check `ecr.dkr`/`s3` endpoints exist; confirm the tag |
| `OutOfMemoryError` | memory limit | raise `task_memory`; check for a context-size regression |
| `Essential container exited` | application crash | read the logs; usually config |

**Note the asymmetry:** a *running* task has already read its secrets, so a
Secrets Manager problem looks like a healthy service until something restarts.
If tasks fail to start but the service looks fine, suspect secrets first.

### High error rate

```bash
aws logs filter-log-events --log-group-name $LOG --region $REGION \
  --start-time $(( ($(date +%s) - 900) * 1000 )) \
  --filter-pattern '{ $.level = "ERROR" }' \
  --query 'events[].message' --output text | head -30
```

| Error | Meaning | Action |
|---|---|---|
| `401` / `invalid_api_key` | key rotated, revoked, or secret empty | §4 |
| `404 model … does not exist` | provider retired the model | pin a current model; §5 |
| `429` | rate limited | check volume; raise provider quota |
| `AccessDenied` on `GetSecretValue` | **investigate as security** — may be credentials used off-VPC | §6 |
| Connection timeouts to the model host | egress path | §3 below |

### Egress failures

```bash
# Did the firewall refuse something?
aws logs filter-log-events --log-group-name /aws/vpc/cascade-support-agent-flow-logs \
  --region $REGION --filter-pattern 'REJECT' --max-items 20
```

If a *new* host is being refused, that is the allow-list working. Someone added
an outbound dependency without a change to `allowed_egress_hosts` — the fix is a
reviewed Terraform change, not a console edit.

### Guardrail false positives

Blocked requests look like success in every RED metric — error rate flat,
latency *improves*, because blocked requests skip the model and the tools.

```bash
aws cloudwatch get-metric-statistics --namespace Cascade/SupportAgent \
  --metric-name GuardrailBlocks --start-time $(date -u -v-6H +%FT%TZ) \
  --end-time $(date -u +%FT%TZ) --period 900 --statistics Sum --region $REGION
```

A step change in block rate with a flat error rate means a guardrail pattern
regressed. Roll back the guardrail configuration; it is independently
deployable precisely so this does not require a full application rollback.

---

## 4 · Secrets

```bash
# Is it populated? (metadata only — this does NOT print the value)
aws secretsmanager describe-secret --region $REGION \
  --secret-id cascade-support-agent/model-api-key \
  --query '{updated:LastChangedDate,rotated:LastRotatedDate,versions:length(VersionIdsToStages)}'

# Update (piped — never as an argv argument)
printf '%s' "$NEW_KEY" | aws secretsmanager put-secret-value --region $REGION \
  --secret-id cascade-support-agent/model-api-key --secret-string file:///dev/stdin

# Running tasks keep the OLD value. Restart to pick it up.
aws ecs update-service --cluster $CLUSTER --service $SERVICE \
  --force-new-deployment --region $REGION
```

**Rotation is manual, every 90 days.** Procedure: create the new key at the
provider → write it to Secrets Manager → force a new deployment → verify → only
then revoke the old key at the provider. Revoking first causes an outage during
the deployment window.

---

## 5 · Model provider changes

Providers retire models, sometimes without notice. The symptom is a `404` with
`model_not_found`, which reads like a configuration error.

```bash
# What does the provider actually serve right now?
curl -s https://api.groq.com/openai/v1/models \
  -H "Authorization: Bearer $KEY" | jq -r '.data[].id' | sort
```

Pick a model that supports **tool calling** — the agent's handoffs are function
calls, so a model without it cannot route at all. Update `model` in Terraform,
run the evaluation suite against the candidate before deploying, then deploy.

---

## 6 · Security events

**Stop and page Cascade security. Do not investigate alone.**

| Trigger | First action |
|---|---|
| `AccessDenied` on `GetSecretValue` from outside the VPC | possible credential theft — preserve logs, page security |
| Egress attempt to an unknown host | preserve flow logs, page security |
| Unexpected IAM change in CloudTrail | page security; do not revert until told |
| Card number found in logs | halt the service, preserve evidence, page security and compliance |

**Containment without destroying evidence:**

```bash
# Stop processing. Does NOT delete logs or state.
aws ecs update-service --cluster $CLUSTER --service $SERVICE \
  --desired-count 0 --region $REGION
```

Scale to zero rather than deleting anything. The logs, the flow logs and the
DynamoDB contents are the investigation.

---

## 7 · Routine

| Task | Frequency | Command |
|---|---|---|
| Review image scan findings | weekly | `aws ecr describe-image-scan-findings` |
| Rotate model API key | 90 days | §4 |
| Terraform drift check | weekly (CI) | `terraform plan -detailed-exitcode` |
| Verify controls | monthly + after any change | `verify_deployment.py --env aws` |
| Review break-glass sessions | monthly | CloudTrail, filter on `IncidentId` |
| Restore test from PITR | quarterly | see knowledge-transfer.md |

The monthly break-glass review is the one that gets skipped. It is also the one
that would notice a session with no matching incident ticket.

---

## 8 · Escalation

| Level | Who | When |
|---|---|---|
| 1 | Cascade platform on-call | all alerts |
| 2 | Cascade platform lead | > 30 min unresolved, or a rollback is needed |
| 3 | Cascade security | anything in §6, immediately |
| 4 | Vendor (FDE team) | design questions, during the 30-day support window |

**After the support window, level 4 is gone.** Everything needed to operate
this system without us is in this runbook and in
[knowledge-transfer.md](knowledge-transfer.md) — that is the test the handover
has to pass.
