#!/usr/bin/env bash
# Apply an environment's configuration on the server: secrets from SSM (as .env lines on stdin) + compose/nginx/livekit files
# that CI unpacked into $DIR/.incoming/. Validates first, applies atomically, rolls back if the stack does not come up.
#
# Streamed by the reusable infra workflow (script text is the ssh command, the secrets are stdin so they never hit `ps`):
#   ssm_to_env.py ... | ssh host "bash -c '<this script>' infra-apply --env staging --services 'redis nginx'"
#
#   --env <staging|prod|test>   directory under $DEPLOY_ROOT
#   --services "<a b c>"        compose services to (re)start; default: the shared infrastructure
#   [--wait <seconds>]          health wait, default 180
set -euo pipefail

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/zepruv/deploy/environments}"
ENV_NAME="" SERVICES="rabbitmq redis livekit livekit-egress nginx datadog-agent" WAIT_SECONDS=180
die() { echo "infra-apply: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="${2:-}"; shift 2 ;;
    --services) SERVICES="${2:-}"; shift 2 ;;
    --wait) WAIT_SECONDS="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$ENV_NAME" =~ ^(staging|prod|test)$ ]] || die "--env must be staging, prod or test"
[[ "$SERVICES" =~ ^[a-z0-9\ -]+$ ]] || die "invalid --services"
[[ "$WAIT_SECONDS" =~ ^[0-9]{1,4}$ ]] || die "invalid --wait"

DIR="$DEPLOY_ROOT/$ENV_NAME"
[ -d "$DIR" ] || die "$DIR does not exist (run setup-vps-staging.sh first)"
cd "$DIR"
umask 077
exec 9>.deploy.lock
flock -n 9 || die "another deployment is running in $ENV_NAME"

INCOMING=".incoming"
NEW_ENV="$(mktemp .env.new.XXXXXX)"
trap 'rm -f "$NEW_ENV"' EXIT

# ---- 1. read + validate the secrets (stdin) ------------------------------------------------------------------------
cat > "$NEW_ENV"
[ -s "$NEW_ENV" ] || die "no variables received on stdin: refusing to replace the environment with an empty one"
if grep -Env "^[A-Za-z_][A-Za-z0-9_]*='[^']*'$" "$NEW_ENV" | cut -d: -f1 | grep -q .; then
  die "line(s) $(grep -Env "^[A-Za-z_][A-Za-z0-9_]*='[^']*'$" "$NEW_ENV" | cut -d: -f1 | tr '\n' ' ')of the input are not NAME='value'"
fi
if grep -Eq "^(ECR_REGISTRY|APP_RELEASE|IMAGE_TAG|DOCKER_GID|[A-Z0-9_]+_TAG)=" "$NEW_ENV"; then die "input contains deploy-managed variables"; fi

# keep what the deploy scripts own (image tags, registry, release) from the current .env
if [ -f .env ]; then grep -E "^(ECR_REGISTRY|APP_RELEASE|IMAGE_TAG|[A-Z0-9_]+_TAG)=" .env >> "$NEW_ENV" || true; fi
# DOCKER_GID is a fact about THIS server (the group that owns the docker socket, which the judge joins to start sandboxes),
# so it is read from the host every time and never stored in SSM: it differs between servers and after a docker reinstall.
DOCKER_SOCK="${DOCKER_SOCK:-/var/run/docker.sock}"   # overridable for tests only
if [ -e "$DOCKER_SOCK" ]; then echo "DOCKER_GID=$(stat -c %g "$DOCKER_SOCK")" >> "$NEW_ENV"; fi
chmod 600 "$NEW_ENV"

compose_file="docker-compose.yml"
[ -f "$INCOMING/docker-compose.yml" ] && compose_file="$INCOMING/docker-compose.yml"

# ---- 2. validate before touching anything ----------------------------------------------------------------------------
echo "==> [$ENV_NAME] validating compose file with the new environment"
docker compose --project-directory "$DIR" --env-file "$NEW_ENV" -f "$compose_file" config -q \
  || die "compose validation failed: nothing was changed"

# ---- 3. apply (with backups so a failure can be undone) ----------------------------------------------------------------
changed=""
backup() { [ -f "$1" ] && cp -p "$1" "$1.prev" || true; }
backup .env
if [ -d "$INCOMING" ]; then
  shopt -s dotglob
  for f in "$INCOMING"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in .env*) die "refusing to install $base" ;; esac
    if ! cmp -s "$f" "$base" 2>/dev/null; then changed="$changed $base"; fi
    backup "$base"
    mv -f "$f" "$base"
  done
  shopt -u dotglob
  rmdir "$INCOMING" 2>/dev/null || true
fi
mv -f "$NEW_ENV" .env
chmod 600 .env

restore() {
  echo "!! restoring previous configuration" >&2
  for f in .env.prev *.prev; do if [ -f "$f" ]; then mv -f "$f" "${f%.prev}"; fi; done
  # shellcheck disable=SC2086
  docker compose up -d $SERVICES >/dev/null 2>&1 || true
}

# shellcheck disable=SC2086
if ! docker compose up -d --wait --wait-timeout "$WAIT_SECONDS" $SERVICES; then
  docker compose ps >&2 || true
  restore
  exit 1
fi

# bind-mounted config changes are not noticed by `up -d`
case " $changed " in *" livekit.yaml "*) docker compose restart livekit >/dev/null 2>&1 || true ;; esac
case " $SERVICES " in
  *" nginx "*)
    cid="$(docker compose ps -q nginx | head -n1 || true)"
    if [ -n "$cid" ]; then
      docker exec "$cid" nginx -t && docker exec "$cid" nginx -s reload || echo "!! nginx config test/reload failed" >&2
    fi ;;
esac

printf '%s %s infra %s\n' "$(date -u +%FT%TZ)" "$ENV_NAME" "${changed:-env-only}" >> .deploy-history
docker compose ps
echo "==> [$ENV_NAME] environment applied ($(grep -c . .env) variables)"
