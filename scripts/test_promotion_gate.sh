#!/usr/bin/env bash
# Tests the prod promotion gate in .github/workflows/deploy.yml (the "Resolve image" step) against a real git history and
# a fake `aws`. Needs Linux + git:
#   docker run --rm -v "$PWD/..:/r:ro" ubuntu:24.04 bash -c 'apt-get update -qq && apt-get install -y -qq git python3 >/dev/null && bash /r/scripts/test_promotion_gate.sh'
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/repo"

# Extract the shell script of the step with `id: r` from deploy.yml
python3 - "$ROOT/.github/workflows/deploy.yml" "$WORK/resolve.sh" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
i = next(n for n, l in enumerate(lines) if l.strip() == "- id: r")
j = next(n for n in range(i, len(lines)) if lines[n].strip() == "run: |")
indent = len(lines[j + 1]) - len(lines[j + 1].lstrip())
out = []
for l in lines[j + 1:]:
    if l.strip() and (len(l) - len(l.lstrip())) < indent:
        break
    out.append(l[indent:] if l.strip() else "")
text = "\n".join(out) + "\n"
text = text.replace("${{ inputs.service }}", "backend-server")  # GitHub expands expressions before the shell runs
open(sys.argv[2], "w").write(text)
PY

# Fake aws: image tags present in "ECR" are listed (in push order) in $FAKE_TAGS
cat > "$WORK/bin/aws" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"--image-ids imageTag="*) all="$*"; want="${all##*imageTag=}"; want="${want%% *}"; for t in $FAKE_TAGS; do [ "$t" = "$want" ] && exit 0; done; exit 1 ;;
  *"describe-images"*"--query"*) printf '%s\t' $FAKE_TAGS; echo ;;
esac
FAKE
chmod +x "$WORK/bin/aws"; export PATH="$WORK/bin:$PATH"

cd "$WORK/repo" || exit 1
git init -q -b main; git config user.email t@t; git config user.name t
git remote add origin "$WORK/repo"                     # `git fetch origin main` works against itself
c() { echo "$1" >> f; git add f; git commit -qm "$1"; git rev-parse HEAD; }
A=$(c a); B=$(c b)                                    # main: A, B
git checkout -q -b staging; S1=$(c s1)                # staging-only commit (not on main)
git checkout -q main
export GITHUB_OUTPUT="$WORK/out" GITHUB_STEP_SUMMARY="$WORK/sum"

run() { : > "$GITHUB_OUTPUT"; ENV_NAME="$1" REPO=zepruv-backend INPUT_SHA="${2:-}" CURRENT_SHA="$B" AWS_REGION=x bash "$WORK/resolve.sh" >"$WORK/log" 2>&1; }
# shellcheck disable=SC2329
out() { grep "^$1=" "$GITHUB_OUTPUT" | cut -d= -f2; }
fail=0; check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; sed 's/^/       /' "$WORK/log" | tail -3; fail=1; fi; }
s12() { echo "${1:0:12}"; }

FAKE_TAGS="sha-$(s12 "$A") staging-ok-$(s12 "$A") sha-$(s12 "$B") sha-$(s12 "$S1") staging-ok-$(s12 "$S1")"
export FAKE_TAGS

FAKE_TAGS="" run staging; check "staging builds a commit whose image does not exist yet" "[ \"\$(out build)\" = true ] && [ \"\$(out tag)\" = sha-$(s12 "$B") ]"
run staging;           check "staging skips the build when the image for the commit already exists (re-run)" "[ \"\$(out build)\" = false ]"
run prod;              check "prod auto-picks the newest staging-verified commit that is ON main (skips S1: verified but not on main)" "[ \"\$(out sha)\" = $A ] && [ \"\$(out build)\" = false ]"
run prod "$(s12 "$S1")"; check "prod refuses a staging-verified commit that is not on main" "[ \$? -ne 0 ] || ! grep -q '^sha=' $GITHUB_OUTPUT"
run prod "$(s12 "$B")";  check "prod refuses a main commit that was never verified on staging" "! grep -q '^sha=' $GITHUB_OUTPUT && grep -q 'never verified on staging' $WORK/log"
FAKE_TAGS="$FAKE_TAGS staging-ok-$(s12 "$B")"
export FAKE_TAGS
run prod "$(s12 "$B")";  check "prod accepts a verified commit that is on main" "[ \"\$(out tag)\" = sha-$(s12 "$B") ]"
FAKE_TAGS="sha-$(s12 "$S1") staging-ok-$(s12 "$S1")"
export FAKE_TAGS
git checkout -q -b squashed main; git checkout -q staging -- f; git commit -qam "squash of staging"; git branch -q -f main squashed; git checkout -q main
run prod "$(s12 "$S1")"; check "prod accepts a squash-merged commit (main has identical content)" "[ \"\$(out sha)\" = $S1 ]"
run prod "zzzz";       check "prod rejects a malformed sha" "grep -q 'must be 12-40 hex' $WORK/log"
FAKE_TAGS=""
export FAKE_TAGS
run prod;              check "prod fails with a clear message when nothing is verified" "grep -q 'No staging-verified image' $WORK/log"
exit $fail
