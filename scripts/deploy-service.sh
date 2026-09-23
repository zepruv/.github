#!/usr/bin/env bash
# Deploy ONE service of an environment on the server, with health verification and automatic rollback.
#
# Streamed over SSH by the reusable deploy workflow (nothing needs to be installed on the server ahead of time
# except Docker, the compose files under /opt/zepruv/deploy/environments/<env>/ and a populated .env):
#
#   { printf '%s\n' "$ECR_PASSWORD"; cat deploy-service.sh; } | \
#     ssh host 'IFS= read -r ECR_PASSWORD; export ECR_PASSWORD; bash -s -- --env staging --service backend-server ...'
#
# The registry password travels on stdin (not on the command line, so it never shows up in `ps`).
#
# Arguments:
#   --env <staging|prod|test>     environment directory under $DEPLOY_ROOT
#   --service <compose service>   e.g. backend-server
#   --tag-var <NAME_TAG>          .env variable that holds this service's image tag, e.g. BACKEND_TAG
#   --tag <image tag>             immutable tag to deploy (e.g. staging-42-a1b2c3d)
#   --registry <ecr registry>     e.g. 123456789012.dkr.ecr.ap-south-2.amazonaws.com
#   [--profile <name>]            compose profile the service belongs to (e.g. full)
#   [--set-release]               also write APP_RELEASE=<tag> (services that report a release, e.g. the backend)
#   [--wait <seconds>]            health wait, default 180
set -euo pipefail

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/zepruv/deploy/environments}"
ENV_NAME="" SERVICE="" TAG_VAR="" TAG="" REGISTRY="" PROFILE="" SET_RELEASE=0 WAIT_SECONDS=180

die() { echo "deploy-service: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="${2:-}"; shift 2 ;;
    --service) SERVICE="${2:-}"; shift 2 ;;
    --tag-var) TAG_VAR="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --registry) REGISTRY="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --set-release) SET_RELEASE=1; shift ;;
    --wait) WAIT_SECONDS="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# ---- Validate everything that ends up in a file or a command (arguments come from a workflow, but be strict) ----
[[ "$ENV_NAME" =~ ^(staging|prod|test)$ ]] || die "--env must be staging, prod or test"
[[ "$SERVICE" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "invalid --service"
[[ "$TAG_VAR" =~ ^[A-Z][A-Z0-9_]*_TAG$ ]] || die "invalid --tag-var (expected NAME_TAG)"
[[ "$TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "invalid --tag"
[[ "$REGISTRY" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$ ]] || die "invalid --registry"
[[ -z "$PROFILE" || "$PROFILE" =~ ^[a-z0-9-]+$ ]] || die "invalid --profile"
[[ "$WAIT_SECONDS" =~ ^[0-9]{1,4}$ ]] || die "invalid --wait"
[ -n "${ECR_PASSWORD:-}" ] || die "ECR_PASSWORD was not provided on stdin"

DIR="$DEPLOY_ROOT/$ENV_NAME"
[ -d "$DIR" ] || die "$DIR does not exist (bootstrap the server first)"
cd "$DIR"
[ -f .env ] || die "$DIR/.env is missing (copy .env.example and fill it in)"

# One deploy at a time per environment
exec 9>.deploy.lock
flock -n 9 || die "another deployment is running in $ENV_NAME"

compose() {
  if [ -n "$PROFILE" ]; then docker compose --profile "$PROFILE" "$@"; else docker compose "$@"; fi
}

get_env() { grep -E "^$1=" .env | tail -n1 | cut -d= -f2- || true; }

set_env() {  # set_env NAME VALUE : replace the line or append it, preserving file mode
  local name="$1" value="$2" tmp
  tmp="$(mktemp .env.XXXXXX)"
  awk -v n="$name" -v v="$value" 'BEGIN{done=0} $0 ~ "^"n"=" {print n"="v; done=1; next} {print} END{if(!done) print n"="v}' .env > "$tmp"
  chmod --reference=.env "$tmp" 2>/dev/null || chmod 600 "$tmp"
  mv "$tmp" .env
}

wait_healthy() {  # returns 0 when the container is healthy (or running for 20s if it has no healthcheck)
  local cid deadline status
  cid="$(compose ps -q "$SERVICE" | head -n1)"
  [ -n "$cid" ] || return 1
  deadline=$(( $(date +%s) + WAIT_SECONDS ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealthcheck{{end}}' "$cid" 2>/dev/null || echo gone)"
    case "$status" in
      healthy) return 0 ;;
      unhealthy|gone) return 1 ;;
      nohealthcheck) sleep 20; [ "$(docker inspect --format '{{.State.Running}}' "$cid" 2>/dev/null)" = "true" ] && return 0 || return 1 ;;
    esac
    sleep 5
  done
  return 1
}

echo "==> [$ENV_NAME] deploying $SERVICE -> $TAG_VAR=$TAG"
printf '%s' "$ECR_PASSWORD" | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
unset ECR_PASSWORD

PREVIOUS_TAG="$(get_env "$TAG_VAR")"
PREVIOUS_RELEASE="$(get_env APP_RELEASE)"
echo "    previous $TAG_VAR: ${PREVIOUS_TAG:-<none>}"

set_env ECR_REGISTRY "$REGISTRY"
set_env "$TAG_VAR" "$TAG"
[ "$SET_RELEASE" -eq 1 ] && set_env APP_RELEASE "$TAG"

compose pull "$SERVICE"
compose up -d --no-deps "$SERVICE"

if wait_healthy; then
  echo "==> $SERVICE is healthy on $TAG"
  printf '%s %s %s %s\n' "$(date -u +%FT%TZ)" "$ENV_NAME" "$SERVICE" "$TAG" >> .deploy-history
  docker image prune -f --filter "until=168h" >/dev/null || true
  compose ps "$SERVICE"
  exit 0
fi

echo "!! $SERVICE did not become healthy within ${WAIT_SECONDS}s" >&2
compose logs --tail=60 "$SERVICE" >&2 || true
if [ -n "$PREVIOUS_TAG" ]; then
  echo "==> rolling back $SERVICE to $PREVIOUS_TAG" >&2
  set_env "$TAG_VAR" "$PREVIOUS_TAG"
  if [ "$SET_RELEASE" -eq 1 ] && [ -n "$PREVIOUS_RELEASE" ]; then set_env APP_RELEASE "$PREVIOUS_RELEASE"; fi
  compose up -d --no-deps "$SERVICE"
  if wait_healthy; then echo "==> rollback succeeded; $SERVICE is running $PREVIOUS_TAG" >&2; else echo "!! rollback ALSO unhealthy: manual intervention needed" >&2; fi
else
  echo "!! no previous tag recorded: nothing to roll back to" >&2
fi
exit 1
