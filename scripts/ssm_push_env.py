#!/usr/bin/env python3
"""Upload a filled-in .env file to AWS SSM Parameter Store as SecureStrings (run from your laptop).

  ./ssm_push_env.py --env staging --file .env.staging --dry-run     # show what would be written
  ./ssm_push_env.py --env staging --file .env.staging               # write /zepruv/staging/<NAME> for every variable

Standard tier + the default aws/ssm key = free. Values never appear on a command line or in output.
Skipped on purpose: empty values (SSM cannot store them), and names owned by the deploy scripts (ECR_REGISTRY, *_TAG, APP_RELEASE).
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

import ssm_to_env as rules

LINE_RE = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$")


def parse_env(text):
    values = {}
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        m = LINE_RE.match(raw)
        if not m:
            continue
        name, value = m.groups()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        elif " #" in value:  # inline comment on an unquoted value
            value = value.split(" #", 1)[0].rstrip()
        values[name] = value
    return values


def plan(values):
    """-> (to_write, skipped[(name, reason)])"""
    to_write, skipped = {}, []
    for name, value in values.items():
        if rules.MANAGED_RE.match(name):
            skipped.append((name, "managed by the deploy scripts"))
        elif value == "":
            skipped.append((name, "empty value"))
        elif "\n" in value or "'" in value:
            skipped.append((name, "contains a newline or single quote (unsupported): change the value"))
        else:
            to_write[name] = value
    return to_write, skipped


def put(env, name, value, region, profile, kms_key):
    body = {"Name": f"/zepruv/{env}/{name}", "Value": value, "Type": "SecureString", "Overwrite": True, "Tier": "Standard"}
    if kms_key:
        body["KeyId"] = kms_key
    fd, path = tempfile.mkstemp(prefix="ssm-")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(body, f)
        cmd = ["aws", "ssm", "put-parameter", "--cli-input-json", f"file://{path}", "--region", region, "--output", "text", "--query", "Version"]
        if profile:
            cmd += ["--profile", profile]
        return subprocess.run(cmd, capture_output=True, text=True)
    finally:
        os.unlink(path)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", required=True, choices=["staging", "prod", "test"])
    ap.add_argument("--file", required=True)
    ap.add_argument("--region", default="ap-south-2")
    ap.add_argument("--profile", default=None, help="AWS CLI profile")
    ap.add_argument("--kms-key", default=None, help="customer key id/alias (default: the free aws/ssm key)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    with open(args.file) as f:
        to_write, skipped = plan(parse_env(f.read()))
    for name, why in skipped:
        print(f"skip   {name}: {why}")
    failures = 0
    for name in sorted(to_write):
        if args.dry_run:
            print(f"would write /zepruv/{args.env}/{name}")
            continue
        r = put(args.env, name, to_write[name], args.region, args.profile, args.kms_key)
        if r.returncode == 0:
            print(f"wrote  /zepruv/{args.env}/{name} (version {r.stdout.strip()})")
        else:
            failures += 1
            print(f"FAILED /zepruv/{args.env}/{name}: {r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'unknown error'}")
    print(f"{len(to_write)} variable(s), {len(skipped)} skipped, {failures} failed" + (" (dry run)" if args.dry_run else ""))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
