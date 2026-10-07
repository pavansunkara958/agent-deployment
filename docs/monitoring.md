# Monitoring & Observability Requirements

Two classes of signal, and the second is the one standard APM does not have.

**RED signals** — error rate, latency, throughput — catch an agent that is
failing loudly. That is the easy case.

**Behavioural signals** — guardrail block rate, routing mix, refusal rate,
tool-error rate — catch an agent that is failing *quietly*. Nothing throws,
latency is normal or better, and the service looks healthy while doing the
wrong thing. This is where agent incidents actually live.

---

## Signals emitted

| Signal | Type | Namespace / group |
|---|---|---|
| `Requests`, `Errors` | counter | `Cascade/SupportAgent` |
| `RequestDuration` | histogram | `Cascade/SupportAgent` |
| `TokensInput`, `TokensOutput`, `CostUSD` | counter | `Cascade/SupportAgent` |
| `ToolCalls` by tool and outcome (`ok` / `refused` / `error`) | counter | `Cascade/SupportAgent` |
| `GuardrailBlocks` by layer and reason | counter | `Cascade/SupportAgent` |
| `Handoffs` by target agent | counter | `Cascade/SupportAgent` |
| Structured decision logs (JSON) | logs | `/aws/ecs/cascade-support-agent` |
| Network connections | logs | `/aws/vpc/…-flow-logs` |
| API calls | audit | CloudTrail |

**`ToolCalls` separates `refused` from `error` deliberately.** A refund refused
for exceeding the $200 ceiling is the control working. Folding it into an error
rate fakes an incident and hides a real one in the noise.

**Tool arguments are hashed, never logged.** Enough to spot a retry loop
repeating the same call; not enough to leak a customer.

---

## Alarms

| # | Alarm | Threshold | Severity | Runbook |
|---|---|---|---|---|
| A1 | Error rate | > 5% for 10 min | critical | runbook §3 |
| A2 | p95 latency | > 2.5s for 2 periods | warning | runbook §3 |
| A3 | Cost per request | > 2.5× baseline | warning | runbook §3 |
| A4 | **Guardrail block rate step change** | > 2× 7-day baseline | **critical** | runbook §3 |
| A5 | Tool error rate | > 8% | warning | runbook §3 |
| A6 | Tasks running < desired | any, 5 min | critical | runbook §3 |
| A7 | **`AccessDenied` on `GetSecretValue`** | any | **critical — security** | runbook §6 |
| A8 | Flow log REJECT to a new host | any | warning — security | runbook §3 |
| A9 | Secret age | > 90 days | warning | runbook §4 |
| A10 | Deployment rollback triggered | any | warning | runbook §2 |

**A4 is the one worth defending.** A regressed guardrail makes every RED metric
look *better* — blocked requests skip the model and the tools, so latency drops
and cost falls while customers stop getting answers. Without A4, that failure
is invisible until someone complains.

**A7 is a security alarm, not an availability one.** The task role can only
read secrets from inside the VPC; a denial means credentials were used from
somewhere else.

Every alarm names a runbook section. An alarm without one is a page that starts
with "what does this mean?", at 3am, from someone who did not write it.

---

## Dashboard

One CloudWatch dashboard, four sections, ordered by the question being asked:

1. **Is it up?** — requests, errors, p50/p95/p99, task count
2. **What is it costing?** — tokens, cost per request, daily spend
3. **Is it behaving?** — guardrail blocks by reason, routing mix, tool outcomes,
   refusal rate
4. **What do I open first?** — recent errors with trace ids

Section 3 is the section a standard dashboard does not have, and the one that
catches a silent regression.

---

## Verification

An observability stack fails in a particular way: **it reports green.** A
metric that is never emitted shows as zero, and zero looks like health.

- **Alarms are fire-drilled** before go-live — each one triggered deliberately
  and confirmed to page the right rota. An alarm that has never fired is a
  hypothesis.
- **Metric emission is asserted** by `verify_deployment.py`; a deployment that
  produces no telemetry fails the gate.
- **Log retention is bounded** (90 days). Indefinite retention of support
  transcripts is a liability, not a feature.
