#!/usr/bin/env bash
# Tests deploy-service.sh in isolation with a fake `docker`. Needs Linux (flock, GNU coreutils):
#   docker run --rm -v "$PWD:/s:ro" ubuntu:24.04 bash /s/test_deploy_service.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export DEPLOY_ROOT="$WORK/deploy"; mkdir -p "$DEPLOY_ROOT/staging" "$WORK/bin"
export PATH="$WORK/bin:$PATH" FAKE_LOG="$WORK/docker.log"

# Fake docker: records every call. Health of the service comes from FAKE_HEALTH_<TAG> (default healthy).
cat > "$WORK/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_LOG"
case "$*" in
  *"compose"*" ps -q"*) echo "container123" ;;
  "inspect --format {{if .State.Health}}"*) tag="$(grep -E '^BACKEND_TAG=' "$DEPLOY_ROOT/staging/.env" | cut -d= -f2-)"; var="FAKE_HEALTH_${tag//[^A-Za-z0-9]/_}"; echo "${!var:-healthy}" ;;
  "login "*) cat >/dev/null ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/docker"

fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }
reset_env() { printf 'ECR_REGISTRY=old\nBACKEND_TAG=prev-1\nAPP_RELEASE=prev-1\nKEEP=me\n' > "$DEPLOY_ROOT/staging/.env"; chmod 640 "$DEPLOY_ROOT/staging/.env"; : > "$FAKE_LOG"; }
run() { { printf 'secret-pw\n'; cat "$HERE/deploy-service.sh"; } | { IFS= read -r ECR_PASSWORD; export ECR_PASSWORD; bash -s -- "$@"; }; }
ARGS=(--env staging --service backend-server --tag-var BACKEND_TAG --registry 123456789012.dkr.ecr.ap-south-2.amazonaws.com --set-release --wait 10)

reset_env
run "${ARGS[@]}" --tag staging-7-abc1234 >/dev/null 2>&1; rc=$?
check "healthy deploy exits 0" "[ $rc -eq 0 ]"
check "tag written" "grep -q '^BACKEND_TAG=staging-7-abc1234$' $DEPLOY_ROOT/staging/.env"
check "release written" "grep -q '^APP_RELEASE=staging-7-abc1234$' $DEPLOY_ROOT/staging/.env"
check "unrelated env lines untouched" "grep -q '^KEEP=me$' $DEPLOY_ROOT/staging/.env"
check "registry updated" "grep -q '^ECR_REGISTRY=123456789012' $DEPLOY_ROOT/staging/.env"
check "file mode preserved" "[ \"\$(stat -c %a $DEPLOY_ROOT/staging/.env)\" = 640 ]"
check "password never on a command line" "! grep -q secret-pw $FAKE_LOG"
check "image pulled then service recreated with --no-deps" "grep -q 'pull backend-server' $FAKE_LOG && grep -q 'up -d --no-deps backend-server' $FAKE_LOG"
check "deploy recorded" "grep -q 'staging backend-server staging-7-abc1234' $DEPLOY_ROOT/staging/.deploy-history"

reset_env
export FAKE_HEALTH_staging_8_bad0000=unhealthy
run "${ARGS[@]}" --tag staging-8-bad0000 >/dev/null 2>&1; rc=$?
check "unhealthy deploy exits 1" "[ $rc -eq 1 ]"
check "rolled back to previous tag" "grep -q '^BACKEND_TAG=prev-1$' $DEPLOY_ROOT/staging/.env"
check "rolled back release too" "grep -q '^APP_RELEASE=prev-1$' $DEPLOY_ROOT/staging/.env"
check "service restarted after rollback" "[ \$(grep -c 'up -d --no-deps backend-server' $FAKE_LOG) -eq 2 ]"

reset_env
for bad in "--tag ../../etc" "--tag has\ space" "--env production" "--service Bad_Name" "--registry evil.example.com"; do
  # shellcheck disable=SC2086
  args=("${ARGS[@]}" --tag ok-tag); eval "run ${args[*]} $bad" >/dev/null 2>&1; rc=$?
  check "rejects $bad" "[ $rc -ne 0 ]"
done
check "rejected runs never touched docker compose" "! grep -q 'compose' $FAKE_LOG"

exit $fail
