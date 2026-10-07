# IAM Design

Four roles, separated by **what they are for** rather than by what is
convenient. Implementation: [`infra/terraform/iam.tf`](../infra/terraform/iam.tf).

---

## The roles

| Role | Assumed by | Can do | Cannot do |
|---|---|---|---|
| `…-execution` | ECS service (infrastructure) | pull the image, create log streams | read secrets, touch data |
| `…-task` | the running agent | read 2 named secrets, use 1 table, emit metrics | ECR, arbitrary logs, any other secret |
| `…-deploy` | GitHub Actions via OIDC | push images, update this service | **read any secret** |
| `…-breakglass` | named humans, MFA, ≤1h | describe, restart, shell in | **read any secret** |

### Why execution and task are separate

These are routinely merged, and merging them is the most common IAM mistake in
an ECS deployment.

The **execution role** belongs to the ECS infrastructure. It pulls the image
and creates log streams *before the container starts*. The **task role** is
what the application code runs as.

If they are one role, the application inherits ECR pull and log-group
permissions it has no use for — and an attacker who achieves code execution in
the container inherits them too. Separated, the blast radius of a compromised
container is: two secrets, one DynamoDB table, one metric namespace.

`verify_deployment.py` asserts `taskRoleArn != executionRoleArn`, because this
is the kind of thing that gets merged during a late-night debugging session and
never un-merged.

---

## The conditions that make it least-privilege

A policy scoped to named ARNs is *good*. The conditions are what make it
*enforceable*.

### Task role — secrets

```json
{
  "Effect": "Allow",
  "Action": ["secretsmanager:GetSecretValue"],
  "Resource": ["arn:…:secret:cascade-support-agent/model-api-key-*",
               "arn:…:secret:cascade-support-agent/datastore-*"],
  "Condition": {
    "StringEquals": { "aws:SourceVpce": "vpce-0abc…" }
  }
}
```

Two named secrets, not `*`. And the `aws:SourceVpce` condition means the call
must originate from inside the VPC: **task credentials exfiltrated from the
container and replayed from anywhere else fail.** That converts credential
theft from a successful attack into a CloudTrail `AccessDenied` with an
attacker's source IP attached.

### Task role — KMS

```json
"Condition": { "StringEquals": { "kms:ViaService": "secretsmanager.eu-west-2.amazonaws.com" } }
```

The task can decrypt **only through Secrets Manager**. It cannot call
`kms:Decrypt` directly against arbitrary ciphertext, which closes the path where
a key grant intended for one purpose becomes a general decryption oracle.

### Deploy role — PassRole

```json
{
  "Action": ["iam:PassRole"],
  "Resource": ["…:role/cascade-support-agent-task", "…:role/cascade-support-agent-execution"],
  "Condition": { "StringEquals": { "iam:PassedToService": "ecs-tasks.amazonaws.com" } }
}
```

`iam:PassRole` is the permission most often granted carelessly. Without
`iam:PassedToService`, a pipeline that can pass these roles can attach them to
*anything that accepts a role* — an EC2 instance, a Lambda — and then read
whatever they can read from somewhere with no VPC condition.

The deploy role also carries an explicit `Deny` on `secretsmanager:GetSecretValue`.
A deployment pipeline has no reason to read application credentials, and
pipelines are a frequent exfiltration path because their logs are widely
readable.

### Deploy role — OIDC trust

```json
"StringLike": {
  "token.actions.githubusercontent.com:sub": "repo:cascade-retail/support-agent-deploy:ref:refs/heads/main"
}
```

Pinned to one repository **and one branch**. Pinning only the repo is a common
error: a pull request from a fork can then run a workflow that assumes the
deployment role.

### Execution and task trust — confused deputy

```json
"Condition": {
  "StringEquals": { "aws:SourceAccount": "123456789012" },
  "ArnLike": { "aws:SourceArn": "arn:aws:ecs:eu-west-2:123456789012:*" }
}
```

Without these, any ECS task in any AWS account could assume these roles if the
ARN leaked. Both conditions are needed: account alone permits any service in
that account.

### Break-glass — reason required

```json
"Condition": {
  "Bool": { "aws:MultiFactorAuthPresent": "true" },
  "NumericLessThan": { "aws:MultiFactorAuthAge": "3600" },
  "StringLike": { "aws:RequestTag/IncidentId": "INC-*" }
}
```

MFA, re-authenticated within the hour, and **an incident id that appears in
CloudTrail on every action taken in that session**. Access without a stated
reason is not access; it is an audit finding waiting to happen.

The role can restart the service and shell into a container. It explicitly
cannot read secrets — if an engineer needs the model API key to debug, the
design is wrong, and the rotation that should follow is a cost nobody remembers
to pay.

---

## Permissions boundary

Every role created by this stack carries one. The boundary:

- allows only the service actions this system legitimately uses
- **denies `iam:*`, `organizations:*`, `account:*` outright**
- **denies everything outside `eu-west-2`**, enforcing data residency in IAM
  rather than only in the Terraform

A boundary is what stops a role that can create roles from creating one more
powerful than itself. It is also what makes the region constraint real: a
misconfigured provider block can deploy to the wrong region, but a request to
another region fails at the IAM layer regardless.

---

## What the customer security team should check

Handed over as a review checklist, because "we used least privilege" is not a
reviewable claim:

| # | Check | Where |
|---|---|---|
| 1 | No policy uses `"Resource": "*"` except where the action does not support scoping (`ecr:GetAuthorizationToken`, `cloudwatch:PutMetricData` — the latter scoped by namespace condition) | `iam.tf` |
| 2 | Task role secrets are named ARNs with a VPC-endpoint condition | `iam.tf` |
| 3 | `iam:PassRole` carries `iam:PassedToService` | `iam.tf` |
| 4 | OIDC trust pins repo **and** ref | `iam.tf` |
| 5 | Every role has a permissions boundary | `verify_deployment.py` |
| 6 | Task role ≠ execution role | `verify_deployment.py` |
| 7 | Deploy and break-glass roles deny secret reads | `iam.tf` |
| 8 | Explicit deny on the cardholder-data bucket | `iam.tf` |

Items 5 and 6 are asserted automatically against the running environment.
`terraform plan` would confirm intent; the verifier confirms reality, and those
diverge the moment someone changes something in the console.

---

## Known gaps

**Secrets rotation is not automated.** The secret is tagged `Rotation: 90d` and
rotation is a manual runbook step. An automatic rotation Lambda for a
third-party API key needs provider-side API support for programmatic key
creation; where that does not exist, an automated rotation that cannot verify
the new key is worse than a calendar reminder. Tracked as a follow-up with the
reasoning recorded.

**No per-tenant isolation.** One task serves all of Cascade's support queues.
If multi-brand isolation is required later, it is a task-per-tenant change plus
a tenant dimension on the IAM conditions — scoped but not built.
