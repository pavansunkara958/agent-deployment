# Security Design Summary

For Cascade Retail Group's security team. Every control states where it is
enforced and how to verify it independently.

---

## Threat model, briefly

| Threat | Control | Verify |
|---|---|---|
| Container compromise → lateral movement | task role scoped to 2 secrets + 1 table; no ingress; capabilities dropped | `verify_deployment.py` §2, §4 |
| Task credentials exfiltrated and replayed | `aws:SourceVpce` condition on secret reads | CloudTrail `AccessDenied` with foreign source IP |
| Prompt injection → unauthorised refund | **$200 ceiling enforced inside the tool**, not in the prompt | agent test suite |
| Card data entering logs or traces | input guardrail (Luhn-validated); tool arguments hashed | agent test suite; sampled log scan |
| Supply chain | immutable ECR tags; scan on push; pinned base image digest | ECR findings |
| Credential leak via CI | OIDC federation; deploy role denies secret reads | `iam.tf` |
| Data egress to an unapproved host | Network Firewall hostname allow-list | `verify_deployment.py` §3 negative test |
| Insider / unexplained access | break-glass requires MFA + incident id, logged | CloudTrail |

---

## 1 · Secrets management

**Nothing sensitive is in git, Terraform, or the task definition.**

Terraform creates **empty secret containers**. Values are written out of band:

```bash
aws secretsmanager put-secret-value \
  --secret-id cascade-support-agent/model-api-key \
  --secret-string file:///dev/stdin   # piped, never an argv argument
```

Three properties this gets right:

- **Not in Terraform state.** A `secret_string` in a resource block is in the
  state file, and the state file is in S3 where more people can read it than
  can read Secrets Manager.
- **Not in shell history.** Piped via stdin, not passed as `--secret-string sk-…`,
  which would land in `~/.zsh_history` and in the process table.
- **Not in the container image or `docker inspect`.** ECS injects secrets at
  task start via `valueFrom`; they exist as process environment only.

Encryption uses a **customer-managed KMS key**, not the AWS-managed default.
The difference that matters: a CMK can be disabled by Cascade. An AWS-managed
key cannot, so "we can revoke access to our own data" is only true with a CMK.

| Secret | Rotation | Owner |
|---|---|---|
| `model-api-key` | 90 days, manual (see IAM design gaps) | Cascade platform |
| `datastore` | on credential change | Cascade platform |

**Nothing reads a secret except the task role**, and it can only do so from
inside the VPC. Deploy and break-glass roles carry explicit denies.

---

## 2 · Data protection

| | |
|---|---|
| At rest | KMS CMK: DynamoDB, CloudWatch Logs, ECR, Secrets Manager |
| In transit | TLS 1.2+ everywhere; AWS traffic over PrivateLink |
| Residency | `eu-west-2` only — enforced by the permissions boundary, not just configuration |
| Retention | conversations 90 days via DynamoDB TTL; logs 90 days |

**Customer text crosses the trust boundary exactly once**: the prompt sent to
`api.groq.com`. That is stated plainly rather than buried, and it carries a
blocking condition — **a signed DPA with zero-retention terms before
production**. It is on the go-live checklist as a blocker, not a follow-up.

**PCI-DSS.** The agent handles refund *requests*; it never touches cardholder
data. Three controls keep it that way:

1. The task role carries an **explicit `Deny`** on the cardholder-data bucket.
   A deny beats a missing allow — it survives someone later attaching a broader
   policy to the role by mistake.
2. The input guardrail blocks Luhn-valid card numbers before the model sees
   them.
3. The output guardrail blocks any card number in a reply, so a PAN cannot be
   echoed back even in a confirmation.

The agent should therefore be **out of PCI scope**. That is Cascade's
assessor's determination to make, not ours; the controls and the evidence are
provided for that assessment.

---

## 3 · Network

Covered in the architecture document. The security-relevant summary:

- **No ingress.** The task security group's ingress block is empty and that
  absence is asserted by the verifier.
- **No general egress.** One allow-listed hostname, enforced at two layers
  (SG: port; Network Firewall: hostname) because security groups cannot filter
  by name.
- **AWS traffic stays on AWS.** Nine interface endpoints plus the S3 gateway.
- **Flow logs on**, `traffic_type = ALL`. REJECT records are what answer "what
  did it try to reach" during an incident.

The local simulation enforces the **same** allow-list via a Squid ACL, so a
developer who adds an outbound call finds out on their laptop. A simulation
that is more permissive than production teaches the wrong lesson.

---

## 4 · Workload hardening

| Control | Setting |
|---|---|
| Root filesystem | read-only; `/tmp` is tmpfs |
| User | `10001:10001`, non-root, pinned uid |
| Linux capabilities | `drop: ALL` |
| Privilege escalation | `no-new-privileges` |
| Base image | `python:3.12-slim`, pinned by digest at release |
| Build artefacts | multi-stage; no compilers or package manager caches in the runtime image |
| Image tags | immutable — a tag cannot be repointed after release |
| Image scanning | on push; `HIGH`/`CRITICAL` blocks promotion |

Read-only root plus tmpfs means **nothing the container writes survives a
restart**, which removes persistence as an option for anything that gets in.

---

## 5 · Audit

| Record | Store | Retention |
|---|---|---|
| AWS API calls | CloudTrail | per Cascade policy (7 years) |
| Network connections | VPC Flow Logs | 90 days |
| Agent decisions, handoffs, tool calls | CloudWatch Logs (structured JSON) | 90 days |
| Guardrail blocks | CloudWatch Logs + metric | 90 days |
| Break-glass sessions | CloudTrail with `IncidentId` tag | 7 years |
| Deployments | git + CloudTrail | indefinite |

**Tool arguments are hashed, never stored.** The hash is enough to spot a retry
loop calling the same tool with the same arguments; it is not enough to leak a
customer. Traces are long-retained and widely readable — the decision belongs
there, the payload does not.

---

## 6 · Go-live blockers

Not recommendations. The system does not go to production until each is true.

- [ ] DPA signed with the model provider, zero-retention terms confirmed
- [ ] Cascade security has reviewed and signed off `iam-design.md`
- [ ] `verify_deployment.py --env aws` passes with zero failures
- [ ] Secrets populated; a task has started successfully using them
- [ ] Network Firewall allow-list confirmed, **including the negative test**
- [ ] CloudTrail confirmed capturing break-glass sessions with `IncidentId`
- [ ] Alarms firing to a rota that is actually on call
- [ ] Named owner accepted for every component in the architecture table
- [ ] Rollback tested end to end, not assumed

The last two fail most often. An unowned service is one nobody patches, and an
untested rollback is a hypothesis you find out about during an incident.

---

## 7 · Residual risks

Stated because a security summary that lists no residual risk has not been
written honestly.

| Risk | Why it remains | Compensating control |
|---|---|---|
| Customer text reaches a third-party model | inherent to the system | DPA; zero retention; guardrails strip PII first |
| Manual secret rotation | provider lacks a programmatic key API | 90-day calendar control; tagged; alarmed if stale |
| Model provider changes behaviour silently | outside our control | pinned model version; evaluation suite detects regressions pre-deploy |
| Prompt injection not fully preventable | open problem | **the control is the $200 tool ceiling, in code** — injection cannot change a Python `if` |
| Single region | no DR region in scope | documented RTO; Terraform redeploys in ~20 minutes |

The injection row is the important one. Guardrails reduce the probability of a
bad instruction reaching a tool; the ceiling inside the tool makes the worst
outcome bounded regardless. **Probability controls and consequence controls are
different things, and only the second one survives an attacker who is cleverer
than your patterns.**
