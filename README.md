# Deploying an AI Agent in a Customer Environment

Taking the multi-agent support triage system from
[support-triage-system](https://github.com/pavansunkara958/support-triage-system)
and deploying it into **Cascade Retail Group's** AWS account as a Forward
Deployed Engineer — customer-controlled, PCI-adjacent, with every constraint
treated as real.

| Deliverable | Document |
|---|---|
| Deployment architecture diagram | [docs/deployment-architecture.md](docs/deployment-architecture.md) |
| IAM design document | [docs/iam-design.md](docs/iam-design.md) |
| Security design summary | [docs/security-design.md](docs/security-design.md) |
| Operational runbook | [docs/runbook.md](docs/runbook.md) |
| Knowledge transfer guide | [docs/knowledge-transfer.md](docs/knowledge-transfer.md) |
| Reusable asset proposal | [docs/reusable-assets.md](docs/reusable-assets.md) |
| Monitoring & observability | [docs/monitoring.md](docs/monitoring.md) |

| Implementation | Path |
|---|---|
| Customer-environment infrastructure | [infra/terraform/](infra/terraform/) |
| Local simulation with the same constraints | [infra/compose/](infra/compose/) |
| Hardened container | [app/Dockerfile](app/Dockerfile) |
| Control verification | [scripts/verify_deployment.py](scripts/verify_deployment.py) |

---

## The customer constraints

Established first. Each removed options rather than adding requirements, which
is why the architecture is as small as it is.

| | Constraint |
|---|---|
| CC1 | Customer's AWS account; we have time-boxed access only |
| CC2 | Data does not leave `eu-west-2` |
| CC3 | **No general internet egress** |
| CC4 | No long-lived credentials anywhere |
| CC5 | Customer is in PCI-DSS scope |
| CC6 | Terraform only; console changes are a finding |
| CC7 | Security team reviews before production |

**CC3 shaped everything.** An agent is by nature a thing that calls an external
model. Reconciling that with "no internet egress" produced a design with
exactly one external hostname, enforced at two layers — and it was the first
question the customer's security team asked.

---

## Run it

The local simulation enforces the **same** constraints as the customer VPC: no
internet except the allow-listed host, secrets from a vault, AWS APIs reachable
only on an internal network.

```bash
cd infra/compose
docker compose up --build
docker compose --profile verify run --rm verifier
```

Against the customer account:

```bash
cd infra/terraform
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan        # read it; any IAM or SG diff is a stop
terraform apply tfplan

python scripts/verify_deployment.py --env aws --prefix cascade
```

**The verifier is the gate, not the plan.** `terraform plan` confirms intent;
the verifier confirms reality. Those diverge the moment someone changes
something in the console during an incident.

---

## Three things worth looking at

**The IAM conditions, not the IAM resources.** A policy scoped to named ARNs is
ordinary. What makes it enforceable is `aws:SourceVpce` on secret reads (task
credentials replayed from outside the VPC fail), `iam:PassedToService` on
PassRole (closes the standard escalation path), and an OIDC trust pinned to
repo **and ref** (a fork PR can otherwise deploy). Details and a reviewer's
checklist in [iam-design.md](docs/iam-design.md).

**The execution role and the task role are separate.** These are routinely
merged, and merging them gives the application ECR and log permissions it has
no use for — which an attacker who reaches the container then also has. The
verifier asserts `taskRoleArn != executionRoleArn`, because this is exactly the
kind of thing that gets merged at 2am and never un-merged.

**The local simulation is as restrictive as production.** Squid enforces the
same hostname allow-list as AWS Network Firewall; the compose network is marked
`internal: true`. A simulation that is easier than production teaches you
nothing — here, adding an outbound dependency fails on a laptop in seconds
rather than in the customer's VPC after a deploy.

---

## What is deliberately not claimed

**The agent itself is not a reusable asset.** It encodes Cascade's queues,
refund policy and escalation paths. The *patterns* travel; the implementation
does not, and packaging it would mean every future customer spends their first
week deleting Cascade's business rules. Reasoning in
[reusable-assets.md](docs/reusable-assets.md).

**Secret rotation is manual.** The provider has no programmatic key-creation
API, and an automated rotation that cannot verify the new key is worse than a
calendar control. Recorded as a gap with its reasoning rather than hidden.

**Residual risks are listed**, including the one that cannot be engineered
away: customer text reaches a third-party model. The compensating control is a
DPA with zero-retention terms, and it is a **go-live blocker** rather than a
follow-up.
