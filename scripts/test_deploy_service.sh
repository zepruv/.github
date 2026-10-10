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
  "create "*) echo "cid-mig" ;;
  "cp "*) mkdir -p "${@: -1}" ;;
  "run --rm "*postgres*) [ "${FAKE_MIGRATE_FAIL:-0}" = 1 ] && exit 1; echo "url-seen:${DATABASE_URL:-none}" >> "$FAKE_LOG" ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/docker"

fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }
reset_env() { printf 'ECR_REGISTRY=old\nBACKEND_TAG=prev-1\nAPP_RELEASE=prev-1\nBACKEND_RELEASE_VERSION=1.0.0\nRELEASE_VERSION=1.0.0\nKEEP=me\n' > "$DEPLOY_ROOT/staging/.env"; chmod 640 "$DEPLOY_ROOT/staging/.env"; : > "$FAKE_LOG"; }
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
for bad in "--tag ../../etc" "--tag has\ space" "--env production" "--service Bad_Name" "--registry evil.example.com" "--release-version 1.2" "--release-version v1.2.3" "--release-version 1.2.3-rc1" "--release-version 01.2.3"; do
  # shellcheck disable=SC2086
  args=("${ARGS[@]}" --tag ok-tag); eval "run ${args[*]} $bad" >/dev/null 2>&1; rc=$?
  check "rejects $bad" "[ $rc -ne 0 ]"
done
check "rejected runs never touched docker compose" "! grep -q 'compose' $FAKE_LOG"

# --- release version ---
reset_env
run "${ARGS[@]}" --tag sha-aaa111111111 --release-version 2.462.0 >/dev/null 2>&1; rc=$?
check "release version: healthy deploy exits 0" "[ $rc -eq 0 ]"
check "release version: per-service variable written (BACKEND_TAG -> BACKEND_RELEASE_VERSION)" "grep -q '^BACKEND_RELEASE_VERSION=2.462.0$' $DEPLOY_ROOT/staging/.env"
check "release version: --set-release also writes RELEASE_VERSION and still APP_RELEASE=<tag>" "grep -q '^RELEASE_VERSION=2.462.0$' $DEPLOY_ROOT/staging/.env && grep -q '^APP_RELEASE=sha-aaa111111111$' $DEPLOY_ROOT/staging/.env"

reset_env
run "${ARGS[@]}" --tag sha-bbb222222222 >/dev/null 2>&1; rc=$?
check "no version given (unversioned image): per-service variable emptied, RELEASE_VERSION falls back to the tag" "[ $rc -eq 0 ] && grep -q '^BACKEND_RELEASE_VERSION=$' $DEPLOY_ROOT/staging/.env && grep -q '^RELEASE_VERSION=sha-bbb222222222$' $DEPLOY_ROOT/staging/.env"

reset_env
run --env staging --service interview-agent --tag-var INTERVIEWER_TAG --registry 123456789012.dkr.ecr.ap-south-2.amazonaws.com --wait 10 --tag sha-ccc333333333 --release-version 3.1.0 >/dev/null 2>&1; rc=$?
check "without --set-release only the service's own variable is written (global names untouched)" "[ $rc -eq 0 ] && grep -q '^INTERVIEWER_RELEASE_VERSION=3.1.0$' $DEPLOY_ROOT/staging/.env && grep -q '^RELEASE_VERSION=1.0.0$' $DEPLOY_ROOT/staging/.env && grep -q '^APP_RELEASE=prev-1$' $DEPLOY_ROOT/staging/.env"

reset_env
export FAKE_HEALTH_sha_ddd444444444=unhealthy
run "${ARGS[@]}" --tag sha-ddd444444444 --release-version 2.463.0 >/dev/null 2>&1; rc=$?
check "release version: an unhealthy deploy rolls the version variables back" "[ $rc -eq 1 ] && grep -q '^BACKEND_RELEASE_VERSION=1.0.0$' $DEPLOY_ROOT/staging/.env && grep -q '^RELEASE_VERSION=1.0.0$' $DEPLOY_ROOT/staging/.env && grep -q '^APP_RELEASE=prev-1$' $DEPLOY_ROOT/staging/.env"

reset_env
echo "MIGRATION_DATABASE_URL='postgresql://u:p@db:5432/x'" >> "$DEPLOY_ROOT/staging/.env"
FAKE_MIGRATE_FAIL=1 run "${ARGS[@]}" --ecr-repository zepruv-backend --migrate --tag sha-eee555555555 --release-version 2.464.0 >/dev/null 2>&1; rc=$?
check "release version: a failed migration restores the version variables" "[ $rc -eq 1 ] && grep -q '^BACKEND_RELEASE_VERSION=1.0.0$' $DEPLOY_ROOT/staging/.env && grep -q '^RELEASE_VERSION=1.0.0$' $DEPLOY_ROOT/staging/.env"

# --- migrations ---
reset_env
run "${ARGS[@]}" --ecr-repository zepruv-backend --migrate --tag staging-9-mig0001 >/dev/null 2>&1; rc=$?
check "--migrate without MIGRATION_DATABASE_URL is skipped, deploy proceeds" "[ $rc -eq 0 ] && ! grep -q 'postgres' $FAKE_LOG && grep -q 'up -d --no-deps backend-server' $FAKE_LOG"

reset_env
echo "MIGRATION_DATABASE_URL='postgresql://u:p@db:5432/x'" >> "$DEPLOY_ROOT/staging/.env"
run "${ARGS[@]}" --ecr-repository zepruv-backend --migrate --tag staging-10-mig0002 >/dev/null 2>&1; rc=$?
check "migrations run before the container is recreated" "[ $rc -eq 0 ] && [ \$(grep -n 'postgres:16-alpine' $FAKE_LOG | head -1 | cut -d: -f1) -lt \$(grep -n 'up -d --no-deps backend-server' $FAKE_LOG | head -1 | cut -d: -f1) ]"
check "migration image comes from the image being deployed" "grep -q 'create 123456789012.dkr.ecr.ap-south-2.amazonaws.com/zepruv-backend:staging-10-mig0002' $FAKE_LOG"
check "the database URL reached the migration container through the environment, unquoted" "grep -q '^url-seen:postgresql://u:p@db:5432/x$' $FAKE_LOG"
check "the database URL is never on a docker command line" "! grep -q '^docker .*u:p@db' $FAKE_LOG"

reset_env
echo "MIGRATION_DATABASE_URL='postgresql://u:p@db:5432/x'" >> "$DEPLOY_ROOT/staging/.env"
FAKE_MIGRATE_FAIL=1 run "${ARGS[@]}" --ecr-repository zepruv-backend --migrate --tag staging-11-mig0003 >/dev/null 2>&1; rc=$?
check "a failed migration exits 1" "[ $rc -eq 1 ]"
check "a failed migration never recreates the service" "! grep -q 'up -d --no-deps backend-server' $FAKE_LOG"
check "a failed migration puts the previous tag back" "grep -q '^BACKEND_TAG=prev-1$' $DEPLOY_ROOT/staging/.env && grep -q '^APP_RELEASE=prev-1$' $DEPLOY_ROOT/staging/.env"

exit $fail
