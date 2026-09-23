#!/usr/bin/env bash
# Tests infra-apply.sh with a fake `docker`. Needs Linux (flock, GNU coreutils):
#   docker run --rm -v "$PWD:/s:ro" ubuntu:24.04 bash /s/test_infra_apply.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export DEPLOY_ROOT="$WORK/deploy"; D="$DEPLOY_ROOT/staging"; mkdir -p "$D" "$WORK/bin"
export PATH="$WORK/bin:$PATH" FAKE_LOG="$WORK/docker.log"

cat > "$WORK/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_LOG"
case "$*" in
  *" config -q"*) [ "${FAKE_CONFIG_FAIL:-0}" = 1 ] && { echo "invalid compose" >&2; exit 1; } ;;
  *"up -d --wait"*) [ "${FAKE_UP_FAIL:-0}" = 1 ] && exit 1 ;;
  *"ps -q"*) echo "cid1" ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/docker"

fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }
reset() {
  rm -rf "$D"; mkdir -p "$D/.incoming"
  printf 'ECR_REGISTRY=old\nBACKEND_TAG=sha-1\nOLD_SECRET=gone\n' > "$D/.env"; chmod 600 "$D/.env"
  echo "v1" > "$D/docker-compose.yml"; echo "v1" > "$D/nginx.conf"; echo "v1" > "$D/livekit.yaml"
  echo "v2" > "$D/.incoming/docker-compose.yml"; echo "v2" > "$D/.incoming/nginx.conf"
  : > "$FAKE_LOG"
}
run() { printf "%s\n" "JWT_SECRET='p\$ss w#rd'" "APP_ENV='staging'" | bash "$HERE/infra-apply.sh" --env staging --services "redis nginx" --wait 5 >"$WORK/out" 2>&1; }

reset; run; rc=$?
check "success exit code" "[ $rc -eq 0 ]"
check "secrets written verbatim, single-quoted" "grep -q \"^JWT_SECRET='p\\\$ss w#rd'\$\" $D/.env"
check "old secrets removed" "! grep -q OLD_SECRET $D/.env"
check "deploy-managed tag preserved" "grep -q '^BACKEND_TAG=sha-1$' $D/.env && grep -q '^ECR_REGISTRY=old$' $D/.env"
check ".env is mode 600" "[ \"\$(stat -c %a $D/.env)\" = 600 ]"
check "incoming compose installed" "grep -q v2 $D/docker-compose.yml && [ ! -d $D/.incoming ]"
check "validated before applying" "grep -n 'config -q' $FAKE_LOG | head -1 | grep -q ."
check "services started with --wait" "grep -q 'up -d --wait --wait-timeout 5 redis nginx' $FAKE_LOG"
check "nginx reloaded" "grep -q 'exec cid1 nginx -s reload' $FAKE_LOG"
check "no secret value in output" "! grep -q 'p.ss w#rd' $WORK/out"

reset; FAKE_CONFIG_FAIL=1 run; rc=$?
check "invalid compose aborts" "[ $rc -ne 0 ]"
check "nothing changed on invalid compose" "grep -q OLD_SECRET $D/.env && grep -q v1 $D/docker-compose.yml"

reset; FAKE_UP_FAIL=1 run; rc=$?
check "unhealthy stack fails" "[ $rc -ne 0 ]"
check "rollback restores env" "grep -q OLD_SECRET $D/.env && ! grep -q JWT_SECRET $D/.env"
check "rollback restores compose" "grep -q v1 $D/docker-compose.yml && grep -q v1 $D/nginx.conf"

reset; printf '' | bash "$HERE/infra-apply.sh" --env staging >"$WORK/out" 2>&1; rc=$?
check "empty input refused" "[ $rc -ne 0 ] && grep -q OLD_SECRET $D/.env"

reset; printf 'BAD LINE\n' | bash "$HERE/infra-apply.sh" --env staging >"$WORK/out" 2>&1; rc=$?
check "malformed line refused" "[ $rc -ne 0 ] && grep -q OLD_SECRET $D/.env"

reset; printf "BACKEND_TAG='evil'\n" | bash "$HERE/infra-apply.sh" --env staging >"$WORK/out" 2>&1; rc=$?
check "managed variable in input refused" "[ $rc -ne 0 ] && grep -q '^BACKEND_TAG=sha-1$' $D/.env"

reset; echo x > "$D/.incoming/.env"; run; rc=$?
check "incoming .env file refused" "[ $rc -ne 0 ]"

reset; printf "A='1'\n" | bash "$HERE/infra-apply.sh" --env staging --services 'x;rm -rf /' >"$WORK/out" 2>&1; rc=$?
check "service list injection refused" "[ $rc -ne 0 ]"

if [ $fail -eq 0 ]; then echo "ALL PASSED"; else echo "FAILURES"; cat "$WORK/out"; exit 1; fi
