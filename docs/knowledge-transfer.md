# Knowledge Transfer Guide

**Purpose:** enable Cascade platform engineering to operate, debug, change and
eventually rebuild this system without us.

**The test this has to pass:** an engineer who has never seen this system can
take it from a page at 3am to a resolved incident, and from a feature request
to a deployed change, using only what is in this repository.

---

## 1 · What this system is, in one page

A customer support triage agent. A **router** reads an incoming message,
decides which specialist should own it, and **hands off**. Three specialists —
billing, technical, account — each with their own tools. Three guardrail
layers. State persists per conversation.

```
customer message
   → input guardrail      (injection, card data, off-topic)   ← can block here
   → router               (no tools of its own)
   → handoff to ONE specialist
   → specialist calls its tools                               ← tool can refuse here
   → output guardrail     (PII, unqualified promises)         ← can block here
   → reply
```

**Four things that are easy to get wrong when changing it:**

**Handoffs are tool calls.** The router "handing off" is the model emitting a
function call. A model without tool-calling support cannot route at all — this
is the first thing to check when evaluating a model change.

**The router has no tools, deliberately.** It cannot answer a question even if
the model tries. Giving it tools to "make it more helpful" breaks the design.

**The $200 refund ceiling is inside the tool, not in the prompt.** No prompt
change can alter a Python `if`. If someone moves that check into instructions
"for flexibility", the control is gone and nothing will fail visibly.

**The input guardrail judges only the newest message.** With session history
the SDK passes the whole conversation; scanning all of it means a message
blocked once re-trips on every later turn and the conversation sticks
permanently. There is a regression test for this.

---

## 2 · Repository map

| Path | What it is | Change it when |
|---|---|---|
| `app/src/agents_def.py` | router + specialists, handoff graph | routing or instructions change |
| `app/src/tools.py` | tools **and the refund ceiling** | business rules change |
| `app/src/guardrails.py` | input/output guardrails | a new attack or false positive |
| `app/src/config.py` | provider switch, models | changing model or endpoint |
| `infra/terraform/` | the whole AWS stack | any infrastructure change |
| `infra/compose/` | local simulation with the same constraints | testing locally |
| `scripts/verify_deployment.py` | asserts the controls are really in force | after any change |
| `docs/` | these documents | when behaviour changes |

---

## 3 · Running it locally

The local environment enforces the **same constraints as production**: no
internet except the allow-listed host, secrets from a vault, AWS APIs on an
internal network only.

```bash
cd infra/compose
docker compose up --build
docker compose --profile verify run --rm verifier
```

**A simulation that is easier than production teaches you nothing.** If you add
an outbound call, this is where it fails — on your laptop, in seconds, instead
of in the customer's VPC after a deploy.

---

## 4 · Making a change

```
1. change the code
2. run the agent's own test suite          (no API calls, ~1 second)
3. run the local simulation                (constraints enforced)
4. run the evaluation suite against a real endpoint
5. open a PR — CI runs terraform plan and the evaluation gate
6. merge to main → CI deploys
7. run verify_deployment.py --env aws
```

**Steps 2 and 7 are the ones that get skipped and shouldn't be.** Step 2 is
free and catches logic errors; step 7 is what confirms that the controls
described in the security design are actually in force afterwards, as opposed
to intended.

### Things that require a security review before merging

- any change to `infra/terraform/iam.tf`
- any change to `allowed_egress_hosts`
- any new outbound dependency
- any change to a guardrail that **widens** what passes
- anything touching PCI-adjacent data paths

---

## 5 · Common changes, worked

**Change the model.** Confirm the candidate supports tool calling (`/v1/models`
then a tool-calling probe — the preflight script does this). Run the evaluation
suite. Update `model` in `terraform.tfvars`. Deploy. The provider retiring a
model is a `404` that reads like a config error; runbook §5 covers it.

**Add a tool.** Implement it in `tools.py` as a plain function, wrap it, then
add it to **one** agent's tool list. Tool scope is the security boundary — the
technical agent cannot issue refunds because it was never given the tool, not
because it was told not to. Widening a toolset is a security review.

**Change the refund ceiling.** One constant in `tools.py`, and a test asserts
it. It is a business rule, so it needs sign-off from whoever owns refund policy
— not just an engineering review.

**Add a guardrail pattern.** Add it, then add a **false-positive test** in the
same PR. A guardrail is only credible if you test what it lets through. Widened
patterns are the most common cause of a silent quality regression; alarm A4
exists for exactly this.

---

## 6 · Rebuilding from nothing

If the account were lost tomorrow:

```bash
cd infra/terraform
terraform init -backend-config=backend.hcl
terraform apply                      # ~20 min; creates everything except secret VALUES

# Secrets are NOT in Terraform. Repopulate from the customer password vault:
printf '%s' "$KEY" | aws secretsmanager put-secret-value \
  --secret-id cascade-support-agent/model-api-key --secret-string file:///dev/stdin

# Image: rebuild from the git tag and push
docker build -t $ECR:$(git rev-parse --short HEAD) app/
docker push $ECR:$(git rev-parse --short HEAD)

python scripts/verify_deployment.py --env aws
```

**RTO ≈ 30 minutes**, dominated by Terraform. Conversation state in DynamoDB is
not rebuilt — it has a 90-day TTL and restoring it is optional; point-in-time
recovery covers the case where it is not.

This procedure is tested quarterly. A disaster recovery plan that has never
been executed is a document, not a plan.

---

## 7 · Handover schedule

| Session | Duration | Who | Exit test |
|---|---|---|---|
| 1 · Architecture and walkthrough | 2h | platform team | they can draw the data flow |
| 2 · Deploy and rollback, hands-on | 2h | platform team | **they deploy and roll back unaided** |
| 3 · Runbook drill | 2h | on-call rota | they resolve 3 injected faults using only the runbook |
| 4 · Security review | 1h | security team | they sign off IAM and network design |
| 5 · Change walkthrough | 2h | platform team | **they ship a real change end to end** |

**Sessions 2, 3 and 5 are exercises, not presentations.** The engineer drives;
we watch and answer questions. A handover where the vendor does the typing has
demonstrated nothing — and the gaps in the documentation only surface when
somebody else tries to follow it.

**Fault injection for session 3** (we break it, they fix it):
empty a secret · point the image tag at a non-existent tag · remove a host from
the egress allow-list · set `desired_count = 0` · widen a guardrail pattern so
block rate doubles.

The last one is deliberately the hardest: every RED metric improves, and the
only signal is alarm A4.

---

## 8 · Support window and what ends

**30 days** of vendor support after session 5. During it: design questions,
pairing on the first real incident, review of the first customer-made change.

**After it, there is no escalation path to us.** That is the point. The success
condition for this engagement is a team that does not need us, and the
documentation is the deliverable that makes that true.

Open items handed over with named owners and dates:

| Item | Owner | Due |
|---|---|---|
| Automate secret rotation (blocked on provider API) | Cascade platform | revisit Q1 |
| DR region decision | Cascade platform lead | Q4 |
| PCI scope determination | Cascade compliance | before go-live |
| Per-tenant isolation (if multi-brand) | not scoped | on request |
