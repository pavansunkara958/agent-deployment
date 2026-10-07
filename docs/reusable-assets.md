# Reusable Asset Proposal

Three candidates from this engagement. One is worth productising now, one is
worth a template, and one should deliberately **not** be reused — and saying
why is part of the proposal.

---

## Asset 1 · `verify_deployment.py` — deployment control verifier

**Recommend: productise.** Highest reuse value of anything built here.

### What it is

A script that asserts the security controls described in a design document are
actually in force **in the running environment** — not that the Terraform
intended them.

### Why it generalises

Every customer deployment produces the same artefact: a security design
describing controls, reviewed and signed off, and then never checked again.
`terraform plan` confirms intent. It does not catch:

- a security group widened in the console during an incident and never reverted
- a secret container created but never populated
- an egress rule permitting more than the document claims
- a task role merged with an execution role during a late-night debug

Those are the gaps that appear between sign-off and reality, and they are the
same gaps at every customer.

### What makes it work

**It fails when a control is missing, including a deliberate negative test** —
attempting a disallowed egress and asserting it is refused. A control that has
never been observed refusing anything has not been tested. That pattern is the
reusable idea; the specific checks are configuration.

### Productisation

| | |
|---|---|
| Effort | ~2 weeks |
| Shape | pip-installable CLI, a YAML control manifest, pluggable check modules |
| Users | every FDE deployment; customer security teams directly |
| Maintenance | ~2 days/quarter as AWS APIs change |

```yaml
# controls.yaml — the control catalogue becomes data
controls:
  - id: NET-001
    check: security_group_no_ingress
    target: "${prefix}-task"
    severity: blocker
  - id: IAM-003
    check: role_has_permissions_boundary
    targets: ["task", "execution", "deploy", "breakglass"]
  - id: NET-004
    check: egress_denied
    host: example.com          # negative test
```

**The compounding value:** a shared control catalogue across engagements means
customer N benefits from a check written for customer 1. A control that one
security team asked for becomes a control every subsequent deployment gets by
default.

---

## Asset 2 · Customer-environment Terraform module

**Recommend: internal template, not a published module.**

### What it is

The VPC + endpoints + Fargate + secrets + least-privilege IAM pattern in
`infra/terraform/`. The shape — no ingress, no general egress, one allow-listed
host, four separated roles with conditions — is the same for any agent deployed
into a customer account.

### Why a template rather than a module

A published module invites `terraform apply` without reading. The IAM design
here is the valuable part, and it is valuable **because** someone understood
each condition. A module hides `iam:PassedToService` behind a variable, and
then nobody knows why it is there — until someone removes it to fix something
and silently reopens the escalation path.

A template is copied and read. That friction is the feature.

### Reusable regardless of form

| Piece | Why it travels |
|---|---|
| Permissions boundary with a region deny | residency becomes an IAM control, not a config convention |
| `aws:SourceVpce` on secret reads | turns credential theft into a detected failure |
| `iam:PassedToService` on PassRole | closes the most common escalation path |
| OIDC trust pinned to repo **and** ref | fork-PR deployment is a real attack |
| Execution/task role separation | the most common ECS IAM mistake |
| Egress allow-list enforced in local dev too | developers discover new dependencies on their laptop |

| | |
|---|---|
| Effort | ~1 week to generalise and document |
| Shape | internal template repo + an annotated IAM pattern library |
| Users | FDE team |

---

## Asset 3 · The agent itself

**Recommend: do not reuse as a product.**

Worth stating explicitly, because it is the thing that looks most reusable and
is not.

The support triage agent is specific to Cascade's queues, tools, refund policy
and escalation paths. The **patterns** generalise — handoff rather than
delegation, tool scope as the security boundary, controls in code rather than
prompts, newest-message guardrail scope. The **implementation** does not.

Packaging it as a product means every future customer inherits Cascade's
business rules and spends their first week removing them. That is slower than
starting from the patterns.

**What to extract instead:** a written patterns document, with the three
defects this design was built to avoid and why each control is where it is.
Roughly 2 days of work, and more valuable than a codebase nobody can safely
delete from.

---

## Priority

| Asset | Value | Effort | Do it? |
|---|---|---|---|
| Deployment control verifier | **high** | 2 weeks | **yes, now** |
| Customer-environment template | medium-high | 1 week | yes, next |
| Agent patterns document | medium | 2 days | yes, cheap |
| Agent as a product | low | high | **no** |

### Why the verifier first

It is the only one that **compounds**. The Terraform template saves setup time
on each engagement — linear. A shared control catalogue means every customer
security review strengthens every future deployment, and the catalogue is worth
more at customer ten than at customer two.

It is also the asset a customer will pay attention to. "Here is a script that
proves your controls are in force, and it fails if they are not" is a different
conversation from "here is our security document".
