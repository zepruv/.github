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
#   --ecr-repository <name>       e.g. zepruv-backend (bare repo name, no registry/tag) - used only to find this
#                                  service's own old local images for retention pruning; harmless to omit (skips it)
#   [--profile <name>]            compose profile the service belongs to (e.g. full)
#   [--set-release]               also write APP_RELEASE=<tag> (services that report a release, e.g. the backend)
#   [--wait <seconds>]            health wait, default 180
#   [--keep <n>]                  local tagged images of this repo to retain (newest N), default 3
#   [--pull-extra "repo=local ..."]  space-separated repo=localtag pairs pulled (and re-tagged to localtag) after
#                                  the main service deploy - e.g. judge's sandbox images, which its own code
#                                  references by a bare local name (docker-images/build-all.sh's local tags), not
#                                  by ECR path. Failure to pull one is non-fatal (logged, does not fail the deploy).
set -euo pipefail

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/zepruv/deploy/environments}"
ENV_NAME="" SERVICE="" TAG_VAR="" TAG="" REGISTRY="" ECR_REPOSITORY="" PROFILE="" SET_RELEASE=0 WAIT_SECONDS=180 KEEP_IMAGES=3 PULL_EXTRA=""

die() { echo "deploy-service: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="${2:-}"; shift 2 ;;
    --service) SERVICE="${2:-}"; shift 2 ;;
    --tag-var) TAG_VAR="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --registry) REGISTRY="${2:-}"; shift 2 ;;
    --ecr-repository) ECR_REPOSITORY="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --set-release) SET_RELEASE=1; shift ;;
    --wait) WAIT_SECONDS="${2:-}"; shift 2 ;;
    --keep) KEEP_IMAGES="${2:-}"; shift 2 ;;
    --pull-extra) PULL_EXTRA="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# ---- Validate everything that ends up in a file or a command (arguments come from a workflow, but be strict) ----
[[ "$ENV_NAME" =~ ^(staging|prod|test)$ ]] || die "--env must be staging, prod or test"
[[ "$SERVICE" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "invalid --service"
[[ "$TAG_VAR" =~ ^[A-Z][A-Z0-9_]*_TAG$ ]] || die "invalid --tag-var (expected NAME_TAG)"
[[ "$TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "invalid --tag"
[[ "$REGISTRY" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$ ]] || die "invalid --registry"
[[ -z "$ECR_REPOSITORY" || "$ECR_REPOSITORY" =~ ^[a-z0-9][a-z0-9._-]{0,254}$ ]] || die "invalid --ecr-repository"
[[ -z "$PROFILE" || "$PROFILE" =~ ^[a-z0-9-]+$ ]] || die "invalid --profile"
[[ "$WAIT_SECONDS" =~ ^[0-9]{1,4}$ ]] || die "invalid --wait"
[[ "$KEEP_IMAGES" =~ ^[0-9]{1,2}$ && "$KEEP_IMAGES" -ge 1 ]] || die "invalid --keep (must be >= 1)"
for pair in $PULL_EXTRA; do
  [[ "$pair" =~ ^[a-z0-9][a-z0-9._-]{0,254}=[a-z0-9][a-z0-9._-]{0,127}$ ]] || die "invalid --pull-extra entry: $pair (expected repo=localtag)"
done
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

prune_old_tagged_images() {  # keeps the newest $KEEP_IMAGES *tagged* local images of $REGISTRY/$ECR_REPOSITORY
  # `docker image prune` (below) only ever removes dangling (untagged) images - a repo:tag still has a name even
  # once nothing references it, so every past deploy's image sits on disk forever unless something explicitly
  # removes it. This is that something: list this service's own images newest-first, keep the top $KEEP_IMAGES,
  # rmi the rest. $KEEP_IMAGES >= 2 always leaves the just-deployed tag and the previous one the rollback path
  # in this script might still need.
  [ -n "$ECR_REPOSITORY" ] || return 0
  local repo="$REGISTRY/$ECR_REPOSITORY"
  # Remove by repo:tag, never by image ID: several tags routinely point at ONE image (a redeploy of unchanged code
  # gets a new sha- tag but the same image), and `docker rmi <id>` refuses to delete an image that has more than
  # one tag ("referenced in multiple repositories") - which the || true below would hide, so nothing was ever pruned.
  # `docker rmi repo:tag` just drops that tag, and the image itself once its last tag goes.
  # Protected tags (just deployed + the rollback target) always stay and count toward $KEEP_IMAGES; the remaining
  # slots go to the newest other tags, everything past that is removed. Doing it in this order matters: tags of an
  # unchanged image all share one creation time, so trimming first and skipping protected tags afterwards can leave
  # the "extra" tag being the protected one, and then nothing gets pruned at all.
  local slots=$((KEEP_IMAGES - 1)) seen=0 ref
  [ -n "$PREVIOUS_TAG" ] && [ "$PREVIOUS_TAG" != "$TAG" ] && slots=$((slots - 1))
  [ "$slots" -lt 0 ] && slots=0
  while IFS= read -r ref; do
    [ "$ref" = "$repo:$TAG" ] && continue
    [ -n "$PREVIOUS_TAG" ] && [ "$ref" = "$repo:$PREVIOUS_TAG" ] && continue
    seen=$((seen + 1))
    [ "$seen" -le "$slots" ] && continue
    echo "    pruning old image tag $ref"
    docker rmi "$ref" >/dev/null 2>&1 || true  # a tag another running container still uses fails harmlessly
  done < <(docker images "$repo" --format '{{.CreatedAt}}|{{.Repository}}:{{.Tag}}' | grep -v ':<none>$' | sort -r | cut -d'|' -f2)
}

pull_extra_images() {  # pulls repo:latest for each --pull-extra pair, tags it to the bare local name the
  # consuming service's own code actually references (e.g. judge's executionService.js spawns "sandbox-python",
  # never an ECR path) - see docker-images/build-all.sh's local tag names for the mapping this must match.
  [ -n "$PULL_EXTRA" ] || return 0
  for pair in $PULL_EXTRA; do
    local repo="${pair%%=*}" localtag="${pair#*=}"
    echo "    pulling $REGISTRY/$repo:latest -> $localtag"
    if docker pull "$REGISTRY/$repo:latest" >/dev/null; then
      docker tag "$REGISTRY/$repo:latest" "$localtag"
    else
      echo "    !! failed to pull $repo (non-fatal: $localtag keeps whatever was already local, if anything)" >&2
    fi
  done
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
  pull_extra_images
  prune_old_tagged_images
  # Dangling = no tag left at all. pull_extra_images moves each sandbox's :latest to the new image, orphaning the
  # previous one; nothing can roll back to an untagged image, and prune skips any image a container still uses.
  docker image prune -f >/dev/null || true
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
