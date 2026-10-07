"""Post-deployment verification.

Asserts that the controls described in the security design are actually in
force — against the running environment, not against the Terraform that was
supposed to create it.

**The distinction matters.** `terraform plan` says what Terraform intends.
It does not catch a security group someone widened in the console, a secret
that was never populated, or an egress rule that permits more than the document
claims. Infrastructure as code describes intent; this checks reality.

Several of these checks are written to FAIL if a control is missing, including
one that deliberately attempts a disallowed action and expects to be refused.
A control that has never been observed refusing anything has not been tested.

Run:
    python scripts/verify_deployment.py --env aws     # against the customer VPC
    python scripts/verify_deployment.py --env local   # against docker compose
"""
from __future__ import annotations

import argparse
import json
import os
import sys

CHECKS: list[tuple[str, bool, str]] = []


def check(name: str, passed: bool, detail: str = "") -> None:
    CHECKS.append((name, passed, detail))
    print(f"  [{'PASS' if passed else 'FAIL'}] {name}")
    if detail:
        print(f"         {detail}")


def section(title: str) -> None:
    print(f"\n[{title}]")


# ---------------------------------------------------------------------------
def verify_aws(prefix: str, region: str) -> None:
    import boto3
    from botocore.exceptions import ClientError

    ecs = boto3.client("ecs", region_name=region)
    ec2 = boto3.client("ec2", region_name=region)
    iam = boto3.client("iam", region_name=region)
    sm = boto3.client("secretsmanager", region_name=region)
    logs = boto3.client("logs", region_name=region)

    name = f"{prefix}-support-agent"

    # -- network boundary -------------------------------------------------
    section("1. NETWORK BOUNDARY")

    vpcs = ec2.describe_vpcs(Filters=[{"Name": "tag:Name",
                                       "Values": [f"{name}-vpc"]}])["Vpcs"]
    check("VPC exists", bool(vpcs), vpcs[0]["VpcId"] if vpcs else "")
    if not vpcs:
        return
    vpc_id = vpcs[0]["VpcId"]

    subnets = ec2.describe_subnets(
        Filters=[{"Name": "vpc-id", "Values": [vpc_id]},
                 {"Name": "tag:Tier", "Values": ["private"]}])["Subnets"]
    check("private subnets do not auto-assign public IPs",
          all(not s["MapPublicIpOnLaunch"] for s in subnets),
          f"{len(subnets)} private subnets")

    sgs = ec2.describe_security_groups(
        Filters=[{"Name": "vpc-id", "Values": [vpc_id]},
                 {"Name": "group-name", "Values": [f"{name}-task"]}])["SecurityGroups"]
    if sgs:
        ingress = sgs[0]["IpPermissions"]
        check("task security group has NO ingress", not ingress,
              "the agent is not a server; any ingress rule is a finding")
        egress_ports = {p.get("FromPort") for p in sgs[0]["IpPermissionsEgress"]}
        check("egress restricted to 443", egress_ports <= {443},
              f"ports: {sorted(p for p in egress_ports if p is not None)}")

    endpoints = ec2.describe_vpc_endpoints(
        Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])["VpcEndpoints"]
    services = {e["ServiceName"].rsplit(".", 1)[-1] for e in endpoints}
    for required in ("secretsmanager", "kms", "logs", "s3"):
        check(f"VPC endpoint present: {required}", required in services,
              "" if required in services
              else "traffic would traverse the NAT gateway instead")

    flow = ec2.describe_flow_logs(
        Filters=[{"Name": "resource-id", "Values": [vpc_id]}])["FlowLogs"]
    check("VPC flow logs enabled", bool(flow),
          "required to answer 'what did it talk to' after the fact")

    # -- identity ---------------------------------------------------------
    section("2. IDENTITY")

    for role_suffix in ("task", "execution", "deploy", "breakglass"):
        role_name = f"{name}-{role_suffix}"
        try:
            role = iam.get_role(RoleName=role_name)["Role"]
        except ClientError:
            check(f"role exists: {role_suffix}", False, "missing")
            continue
        check(f"role exists: {role_suffix}", True)
        check(f"  permissions boundary set: {role_suffix}",
              "PermissionsBoundary" in role,
              "without a boundary, a role that can create roles can escalate")

    # The task role must not be able to read secrets from outside the VPC.
    try:
        pol = iam.get_role_policy(RoleName=f"{name}-task",
                                  PolicyName=f"{name}-task")["PolicyDocument"]
        doc = pol if isinstance(pol, dict) else json.loads(pol)
        secret_stmts = [s for s in doc["Statement"]
                        if "secretsmanager:GetSecretValue" in
                        (s["Action"] if isinstance(s["Action"], list) else [s["Action"]])]
        check("task role scopes secrets to named ARNs",
              all(s["Resource"] != "*" for s in secret_stmts),
              "wildcard secret access would read every secret in the account")
        check("task role requires the VPC endpoint for secrets",
              all("Condition" in s for s in secret_stmts),
              "stolen task credentials used from outside the VPC must fail")
    except ClientError as exc:
        check("task role policy readable", False, str(exc)[:90])

    # -- secrets ----------------------------------------------------------
    section("3. SECRETS")

    for suffix in ("model-api-key", "datastore"):
        sid = f"{name}/{suffix}"
        try:
            meta = sm.describe_secret(SecretId=sid)
        except ClientError:
            check(f"secret exists: {suffix}", False, "missing")
            continue
        check(f"secret exists: {suffix}", True)
        check(f"  encrypted with a customer-managed key: {suffix}",
              bool(meta.get("KmsKeyId")) and "alias/aws/" not in str(meta.get("KmsKeyId")),
              "an AWS-managed key cannot be disabled by the customer")
        check(f"  has a value: {suffix}",
              bool(meta.get("VersionIdsToStages")),
              "an empty secret means the task will crash on start")

    # -- workload ---------------------------------------------------------
    section("4. WORKLOAD")

    svc = ecs.describe_services(cluster=name, services=[name])["services"]
    if svc:
        s = svc[0]
        check("service running", s["status"] == "ACTIVE",
              f"{s['runningCount']}/{s['desiredCount']} tasks")
        check("desired count meets availability target", s["desiredCount"] >= 2,
              "a single task means a task failure is an outage")
        netcfg = s["networkConfiguration"]["awsvpcConfiguration"]
        check("no public IP assigned", netcfg["assignPublicIp"] == "DISABLED")

        td = ecs.describe_task_definition(
            taskDefinition=s["taskDefinition"])["taskDefinition"]
        c = td["containerDefinitions"][0]
        check("read-only root filesystem", c.get("readonlyRootFilesystem") is True)
        check("runs as non-root", c.get("user", "").startswith("10001"))
        check("all Linux capabilities dropped",
              "ALL" in c.get("linuxParameters", {}).get("capabilities", {}).get("drop", []))
        check("secrets injected, not baked into the image",
              bool(c.get("secrets")),
              f"{len(c.get('secrets', []))} secret(s) via valueFrom")

        env_blob = json.dumps(c.get("environment", []))
        leaked = [m for m in ("sk-", "gsk_", "AKIA", "-----BEGIN")
                  if m in env_blob]
        check("no credential-shaped values in plain environment", not leaked,
              f"found: {leaked}" if leaked else "")

        check("task role is not the execution role",
              td.get("taskRoleArn") != td.get("executionRoleArn"),
              "merging them gives the application ECR and log permissions "
              "it has no use for")

    # -- observability ----------------------------------------------------
    section("5. OBSERVABILITY")
    try:
        groups = logs.describe_log_groups(
            logGroupNamePrefix=f"/aws/ecs/{name}")["logGroups"]
        check("log group exists", bool(groups))
        if groups:
            check("log retention is bounded",
                  groups[0].get("retentionInDays") is not None,
                  "indefinite retention of support transcripts is a liability")
            check("logs encrypted with the CMK", bool(groups[0].get("kmsKeyId")))
    except ClientError as exc:
        check("log group readable", False, str(exc)[:90])


# ---------------------------------------------------------------------------
def verify_local() -> None:
    """Against docker compose. Includes a negative test."""
    import httpx

    section("1. SECRETS BACKEND")
    vault = os.getenv("VAULT_ADDR", "http://vault:8200")
    try:
        r = httpx.get(f"{vault}/v1/sys/health", timeout=5)
        check("vault reachable", r.status_code in (200, 429, 472, 501))
    except Exception as exc:
        check("vault reachable", False, f"{type(exc).__name__}")

    section("2. AWS ENDPOINT SIMULATION")
    endpoint = os.getenv("AWS_ENDPOINT_URL", "http://aws-endpoints:4566")
    try:
        r = httpx.get(f"{endpoint}/_localstack/health", timeout=5)
        services = r.json().get("services", {})
        for svc in ("secretsmanager", "dynamodb", "kms"):
            check(f"{svc} available", services.get(svc) in ("available", "running"))
    except Exception as exc:
        check("endpoints reachable", False, f"{type(exc).__name__}")

    section("3. EGRESS BOUNDARY  (negative tests)")
    proxy = os.getenv("EGRESS_PROXY", "http://egress-proxy:3128")

    # Allowed host should pass the proxy ACL.
    try:
        with httpx.Client(proxy=proxy, timeout=10) as c:
            r = c.get("https://api.groq.com/openai/v1/models")
        check("allow-listed host reachable via proxy",
              r.status_code in (200, 401, 403),
              f"HTTP {r.status_code} — auth failures are fine; a refusal is not")
    except Exception as exc:
        check("allow-listed host reachable via proxy", False,
              f"{type(exc).__name__}: {str(exc)[:70]}")

    # A host that is NOT on the list must be refused. This is the check that
    # proves the boundary exists rather than assuming it.
    blocked = False
    try:
        with httpx.Client(proxy=proxy, timeout=10) as c:
            r = c.get("https://example.com")
        blocked = r.status_code in (403, 407, 502, 503)
    except Exception:
        blocked = True
    check("non-allow-listed host REFUSED", blocked,
          "if this passes, the egress allow-list is not being enforced")

    # Direct egress, bypassing the proxy, must fail — the compose network is
    # marked internal, so there is no route at all.
    direct_blocked = False
    try:
        httpx.get("https://example.com", timeout=5)
    except Exception:
        direct_blocked = True
    check("direct egress (no proxy) REFUSED", direct_blocked,
          "the workload network has no route off itself")


# ---------------------------------------------------------------------------
def main() -> int:
    p = argparse.ArgumentParser(description="Verify the deployment's controls")
    p.add_argument("--env", choices=["aws", "local"], default="local")
    p.add_argument("--prefix", default="cascade")
    p.add_argument("--region", default="eu-west-2")
    args = p.parse_args()

    print("=" * 74)
    print(f"DEPLOYMENT VERIFICATION — {args.env}")
    print("=" * 74)

    if args.env == "aws":
        verify_aws(args.prefix, args.region)
    else:
        verify_local()

    passed = sum(1 for _, ok, _ in CHECKS if ok)
    print("\n" + "=" * 74)
    print(f"{passed}/{len(CHECKS)} checks passed")
    failed = [n for n, ok, _ in CHECKS if not ok]
    if failed:
        print("\nFAILED:")
        for n in failed:
            print(f"  - {n}")
        print("\nA failing control is a deployment blocker, not a warning.")
    print("=" * 74)
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
