#!/usr/bin/env python3
"""Turn `aws ssm get-parameters-by-path` JSON (stdin) into docker compose .env lines (stdout).

  aws ssm get-parameters-by-path --path /zepruv/staging/ --with-decryption --output json | ssm_to_env.py --path /zepruv/staging/

Rules (all violations abort with a message that names the parameter, never its value):
  * flat parameters only: /zepruv/staging/JWT_SECRET  ->  JWT_SECRET
  * names must look like env vars
  * values must be single-line and contain no single quote (they are written as '...' so compose never interpolates `$`)
  * names owned by the deploy tooling (ECR_REGISTRY, APP_RELEASE, *_TAG) are refused: they must not live in SSM
"""
import argparse
import json
import re
import sys

NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
MANAGED_RE = re.compile(r"^(ECR_REGISTRY|APP_RELEASE|IMAGE_TAG|[A-Z0-9_]+_TAG)$")


class EnvError(Exception):
    pass


def convert(payload, path, min_keys=1):
    prefix = path if path.endswith("/") else path + "/"
    params = payload.get("Parameters")
    if not isinstance(params, list):
        raise EnvError("input is not the output of get-parameters-by-path")
    lines, problems = {}, []
    for p in params:
        full = p.get("Name", "")
        if not full.startswith(prefix):
            problems.append(f"{full}: outside {prefix}")
            continue
        name = full[len(prefix):]
        value = p.get("Value", "")
        if "/" in name:
            problems.append(f"{full}: nested parameters are not supported")
        elif not NAME_RE.match(name):
            problems.append(f"{full}: '{name}' is not a valid environment variable name")
        elif MANAGED_RE.match(name):
            problems.append(f"{full}: {name} is managed by the deploy scripts; delete it from SSM")
        elif "\n" in value or "\r" in value:
            problems.append(f"{full}: value contains a newline (not supported in .env)")
        elif "'" in value:
            problems.append(f"{full}: value contains a single quote (not supported); rotate it to a value without one")
        else:
            lines[name] = f"{name}='{value}'"
    if problems:
        raise EnvError("\n".join(problems))
    if len(lines) < min_keys:
        raise EnvError(f"only {len(lines)} parameter(s) found under {prefix} (expected at least {min_keys}): wrong path or empty environment?")
    return [lines[k] for k in sorted(lines)]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--path", required=True, help="SSM path prefix, e.g. /zepruv/staging/")
    ap.add_argument("--min-keys", type=int, default=5, help="refuse to write fewer keys than this (guards against a wrong path wiping the env)")
    args = ap.parse_args(argv)
    try:
        out = convert(json.load(sys.stdin), args.path, args.min_keys)
    except (EnvError, json.JSONDecodeError) as e:
        print(f"ssm_to_env: {e}", file=sys.stderr)
        return 1
    sys.stdout.write("\n".join(out) + "\n")
    print(f"ssm_to_env: {len(out)} variable(s) from {args.path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
