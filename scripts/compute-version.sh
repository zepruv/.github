#!/usr/bin/env bash
# Automatic release versioning: MAJOR.RELEASE.HOTFIX (valid SemVer, no zero padding), stored as the git tag vX.Y.Z.
#
#   one merged PR into `staging`                     -> RELEASE + 1, HOTFIX = 0
#   direct push to `staging` (no PR)                 -> RELEASE + 1, HOTFIX = 0   (flagged "direct push" in the notes)
#   PR from hotfix/* merged into `main`              -> HOTFIX + 1 on the last prod release (highest tag reachable from main)
#   PR carrying the label `breaking`                 -> MAJOR + 1, RELEASE = 0, HOTFIX = 0
#   repo without any valid v* tag                    -> 1.1.0
#
# Counter safety: the next number is derived from the HIGHEST valid tag among git tags AND ECR version tags, so a deleted tag
# can never make a number come back. Tags that are not exactly vMAJOR.MINOR.PATCH (v1.2, v01.2.3, v1.2.3-rc1, vfoo) are ignored.
#
# Layers (only the first two touch no GitHub/AWS state, and they are what scripts/test_compute_version.sh exercises most):
#   pure core   next | classify | normalize | reuse | highest | notes      stdin/files in, key=value or text out
#   glue        resolve | mint                                             talk to git and the GitHub API (`gh`)
#
# Subcommands
#   next      --kind staging-pr|direct-push|hotfix|breaking --tags FILE|- [--reachable FILE]
#               tags file: one tag per line, "name" or "name sha" (refs/tags/ prefix allowed)
#               reachable: the tags reachable from main (only used for hotfix)
#               prints version=, tag=, previous=, bump=(seed|release|breaking|hotfix), kind=, direct_push=, hotfix_fallback=
#   classify  [--prs FILE|-] [--direct N]        normalized PR JSON array in; prints kind=, prs=, direct_push=
#   normalize --sha SHA                          raw `GET /repos/{r}/commits/{sha}/pulls` JSON on stdin -> normalized JSON array
#   reuse     --sha SHA --tags FILE|-            highest valid tag that points at SHA ("name sha" lines): prints version=, tag=
#   highest   [--tags FILE|-]                    prints the highest valid version (1.2.3) or nothing
#   notes     --version V --kind K --bump B --sha SHA --prs FILE --direct FILE [--previous TAG] [--repo OWNER/NAME]
#   resolve   (env) decide the version of $SHA without creating anything          -> $OUT_DIR/result.env (+ $GITHUB_OUTPUT)
#   mint      (env) create the tag vX.Y.Z (atomic, retried on collision) and the GitHub Release
#
# Environment of resolve/mint: REPO=owner/name SHA=<commit> OUT_DIR=<dir> GH_TOKEN (gh), ROLE=staging|production (resolve),
#   MAIN_REF=origin/main, EXTRA_TAGS_FILE=<file with ECR version tags, optional>, MINT_RETRIES=5, KIND/BUMP (mint)
# shellcheck disable=SC2153  # REPO, KIND, VERSION are upper case on purpose: they are the environment of resolve/mint
set -euo pipefail
export LC_ALL=C

SEMVER_RE='^v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$'
PROD_BRANCH="main"
STAGING_BRANCH="staging"
MAX_RANGE_COMMITS=50

die() { echo "compute-version: $*" >&2; exit 1; }

# ===================================================================================================================
# pure core
# ===================================================================================================================

# stdin: tag names (optional 2nd column ignored) -> "MAJOR RELEASE HOTFIX" for every valid tag
valid_triples() {
  local name _rest
  while read -r name _rest; do
    name="${name#refs/tags/}"
    name="${name%$'\r'}"
    if [[ "$name" =~ $SEMVER_RE ]]; then echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"; fi
  done || true
}

valid_names() {  # stdin: tag names -> only the valid ones
  local name
  while read -r name; do if [[ "$name" =~ $SEMVER_RE ]]; then echo "$name"; fi; done || true
}

highest_triple() { valid_triples | sort -k1,1n -k2,2n -k3,3n | tail -n 1; }

read_list() {  # read_list FILE|-|"" : prints the content ("" or missing file = nothing)
  case "${1:-}" in
    "") return 0 ;;
    "-") cat ;;
    *) [ -f "$1" ] && cat "$1"; return 0 ;;
  esac
}

cmd_next() {
  local kind="" tags_file="" reach_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) kind="${2:-}"; shift 2 ;;
      --tags) tags_file="${2:-}"; shift 2 ;;
      --reachable) reach_file="${2:-}"; shift 2 ;;
      *) die "next: unknown argument $1" ;;
    esac
  done
  case "$kind" in staging-pr | direct-push | hotfix | breaking) ;; *) die "next: --kind must be staging-pr, direct-push, hotfix or breaking" ;; esac
  [ -n "$tags_file" ] || die "next: --tags is required (use - for stdin)"

  local all reach top m r h bump="$kind" fallback=false direct=false
  all="$(read_list "$tags_file")"
  reach="$(read_list "$reach_file")"
  top="$(printf '%s\n' "$all" | highest_triple)"

  if [ -z "$top" ]; then
    m=1; r=1; h=0; bump=seed
  else
    local tm tr
    read -r tm tr _ <<<"$top"
    case "$kind" in
      staging-pr) m=$tm; r=$((tr + 1)); h=0; bump=release ;;
      direct-push) m=$tm; r=$((tr + 1)); h=0; bump=release; direct=true ;;
      breaking) m=$((tm + 1)); r=0; h=0 ;;
      hotfix)
        local base bm br
        base="$(printf '%s\n' "$reach" | highest_triple)"
        if [ -z "$base" ]; then
          # nothing was ever released from main: there is no prod release to patch, so this is an ordinary release
          m=$tm; r=$((tr + 1)); h=0; bump=release; fallback=true
        else
          read -r bm br _ <<<"$base"
          # next FREE patch of that MAJOR.RELEASE over every known tag, so v2.461.1 existing means v2.461.2
          h="$(printf '%s\n%s\n' "$all" "$reach" | valid_triples | awk -v m="$bm" -v r="$br" '$1==m && $2==r && $3>mx {mx=$3} END{print mx+1}')"
          m=$bm; r=$br; bump=hotfix
        fi ;;
    esac
  fi

  printf 'version=%s.%s.%s\n' "$m" "$r" "$h"
  printf 'tag=v%s.%s.%s\n' "$m" "$r" "$h"
  if [ -n "$top" ]; then printf 'previous=%s\n' "$(printf '%s' "$top" | tr ' ' '.')"; else printf 'previous=\n'; fi
  printf 'bump=%s\nkind=%s\ndirect_push=%s\nhotfix_fallback=%s\n' "$bump" "$kind" "$direct" "$fallback"
}

cmd_highest() {
  local tags_file="-"
  while [ $# -gt 0 ]; do
    case "$1" in --tags) tags_file="${2:-}"; shift 2 ;; *) die "highest: unknown argument $1" ;; esac
  done
  local t
  t="$(read_list "$tags_file" | highest_triple)"
  [ -z "$t" ] || printf '%s\n' "$t" | tr ' ' '.'
}

cmd_reuse() {
  local sha="" tags_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sha) sha="${2:-}"; shift 2 ;;
      --tags) tags_file="${2:-}"; shift 2 ;;
      *) die "reuse: unknown argument $1" ;;
    esac
  done
  if [ -z "$sha" ] || [ -z "$tags_file" ]; then die "reuse: --sha and --tags are required"; fi
  local t
  t="$(read_list "$tags_file" | awk -v s="$sha" '$2 == s {print $1}' | highest_triple)"
  if [ -n "$t" ]; then
    local v; v="$(printf '%s' "$t" | tr ' ' '.')"
    printf 'version=%s\ntag=v%s\n' "$v" "$v"
  fi
}

# raw GET /commits/{sha}/pulls (stdin) -> the merged PRs whose merge commit IS this commit, in the shape the rest uses.
# A later promotion PR (staging -> main) also "contains" the commit; it is not the PR that merged it and is dropped.
cmd_normalize() {
  local sha=""
  while [ $# -gt 0 ]; do
    case "$1" in --sha) sha="${2:-}"; shift 2 ;; *) die "normalize: unknown argument $1" ;; esac
  done
  [ -n "$sha" ] || die "normalize: --sha is required"
  jq -c --arg sha "$sha" '
    [ .[] | select(.merged_at != null and .merge_commit_sha == $sha)
      | { number: .number, title: (.title // ""), body: (.body // ""), url: .html_url, author: (.user.login // "unknown"),
          base: .base.ref, head: .head.ref,
          fork: ((.head.repo.full_name // "") != (.base.repo.full_name // "")),
          labels: [ (.labels // [])[] | .name ] } ]'
}

cmd_classify() {
  local prs_file="-" direct=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --prs) prs_file="${2:--}"; shift 2 ;;
      --direct) direct="${2:-0}"; shift 2 ;;
      *) die "classify: unknown argument $1" ;;
    esac
  done
  [[ "$direct" =~ ^[0-9]+$ ]] || die "classify: --direct must be a number"
  local prs; prs="$(read_list "$prs_file")"
  [ -n "$prs" ] || prs='[]'
  printf '%s' "$prs" | jq -r --argjson direct "$direct" --arg prod "$PROD_BRANCH" '
    . as $p
    | ($p | length) as $n
    | (if any($p[]; any(.labels[]?; ascii_downcase == "breaking")) then "breaking"
       elif $n > 0 and $direct == 0 and all($p[]; .base == $prod and (.head | startswith("hotfix/")) and ((.fork // false) | not)) then "hotfix"
       elif $n == 0 and $direct > 0 then "direct-push"
       else "staging-pr" end) as $kind
    | "kind=\($kind)\nprs=\($n)\ndirect_commits=\($direct)\ndirect_push=\(if $n == 0 and $direct > 0 then "true" else "false" end)"'
}

cmd_notes() {
  local version="" kind="" bump="" sha="" prs_file="" direct_file="" previous="" repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) version="${2:-}"; shift 2 ;;
      --kind) kind="${2:-}"; shift 2 ;;
      --bump) bump="${2:-}"; shift 2 ;;
      --sha) sha="${2:-}"; shift 2 ;;
      --prs) prs_file="${2:-}"; shift 2 ;;
      --direct) direct_file="${2:-}"; shift 2 ;;
      --previous) previous="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      *) die "notes: unknown argument $1" ;;
    esac
  done
  [ -n "$version" ] || die "notes: --version is required"
  local prs direct what
  prs="$(read_list "$prs_file")"; [ -n "$prs" ] || prs='[]'
  direct="$(read_list "$direct_file")"
  case "$bump" in
    seed) what="first version of this repository" ;;
    breaking) what="breaking release (major version bump)" ;;
    hotfix) what="hotfix on the last prod release" ;;
    *) what="release" ;;
  esac
  [ "$kind" = direct-push ] && what="$what - DIRECT PUSH (no pull request, not reviewed)"

  printf '**Version %s** - %s\n\n' "$version" "$what"
  # shellcheck disable=SC2016  # the backticks are Markdown, not a command substitution
  [ -z "$sha" ] || printf 'Commit: `%s`\n\n' "${sha:0:12}"
  printf '### Changes\n\n'
  if [ "$(printf '%s' "$prs" | jq 'length')" -gt 0 ]; then
    # PR text is untrusted: mentions are neutralised (zero-width space) and HTML comments (PR templates) dropped.
    printf '%s' "$prs" | jq -r '
      def clean: (. // "") | gsub("\r"; "") | gsub("(?s)<!--.*?-->"; "") | gsub("@"; "@​") | gsub("^\\s+|\\s+$"; "") | .[0:1200];
      .[] | "- #\(.number) **\(.title | gsub("@"; "@​"))** by @\(.author)"
            + (if (.labels | length) > 0 then " (\(.labels | map(gsub("@"; "@​")) | join(", ")))" else "" end)
            + (if (.body | clean) == "" then "" else "\n" + ((.body | clean) | split("\n") | map("  > " + .) | join("\n")) end)'
  elif [ -z "$direct" ]; then
    printf -- '- (no pull request found for this commit)\n'
  fi
  if [ -n "$direct" ]; then
    printf '\n### Direct pushes (no pull request)\n\n'
    local zw=$'\xe2\x80\x8b' subject
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      subject="${line#* }"
      # shellcheck disable=SC2016  # Markdown backticks
      printf -- '- `%s` %s\n' "${line%% *}" "${subject//@/@$zw}"
    done <<<"$direct"
  fi
  if [ -n "$previous" ] && [ -n "$repo" ]; then
    printf '\n**Full changelog**: https://github.com/%s/compare/%s...v%s\n' "$repo" "$previous" "$version"
  fi
}

# ===================================================================================================================
# glue (git + GitHub API)
# ===================================================================================================================

emit() {  # emit KEY VALUE : single-line values only
  printf '%s=%s\n' "$1" "$2" >> "$OUT_DIR/result.env"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi
}

need_env() { local v; for v in "$@"; do [ -n "${!v:-}" ] || die "environment variable $v is required"; done; }

list_remote_tags() {  # "name sha" for every v* tag of the repository (the remote is the source of truth)
  gh api --paginate "repos/$REPO/git/matching-refs/tags/v" \
    | jq -r '.[] | "\(.ref | sub("^refs/tags/"; "")) \(.object.sha)"'
}

pulls_of_commit() {  # normalized PRs that merged commit $1 ("[]" if none)
  gh api "repos/$REPO/commits/$1/pulls?per_page=100" | cmd_normalize --sha "$1"
}

gather_context() {
  # sets: BASE_TAG (highest valid tag reachable from SHA), writes $OUT_DIR/{prs.json,direct.txt,tags.txt,reachable_main.txt}
  : > "$OUT_DIR/prs.ndjson"; : > "$OUT_DIR/direct.txt"
  BASE_TAG=""
  local triple
  triple="$(git tag --merged "$SHA" | highest_triple)"
  [ -z "$triple" ] || BASE_TAG="v$(printf '%s' "$triple" | tr ' ' '.')"

  local max="$MAX_RANGE_COMMITS" c n
  [ -n "$BASE_TAG" ] || max=1   # first version of the repository: describe this commit only, not the whole history
  # Everything reachable from ANY valid tag is already versioned (hotfix tags sit beside the staging ones), so all of them bound the range.
  local -a range
  mapfile -t range < <({ echo "$SHA"; git tag --merged "$SHA" | valid_names | sed 's#^#^refs/tags/#'; } | git rev-list --first-parent --max-count="$max" --stdin)
  [ "${#range[@]}" -lt "$MAX_RANGE_COMMITS" ] || echo "::warning::more than $MAX_RANGE_COMMITS commits since $BASE_TAG: only the newest are described in the notes"
  # oldest first, so the notes read in merge order
  for ((i = ${#range[@]} - 1; i >= 0; i--)); do
    c="${range[$i]}"
    n="$(pulls_of_commit "$c")"
    if [ "$(printf '%s' "$n" | jq 'length')" -eq 0 ]; then
      printf '%s %s\n' "${c:0:7}" "$(git log -1 --format=%s "$c")" >> "$OUT_DIR/direct.txt"
    else
      # A promotion PR (staging -> main) only moves content that was versioned on staging: it is not a change of its own
      printf '%s' "$n" | jq -c --arg prod "$PROD_BRANCH" --arg stg "$STAGING_BRANCH" \
        'map(select((.base == $prod and .head == $stg) | not))' >> "$OUT_DIR/prs.ndjson"
    fi
  done
  jq -s 'add // []' "$OUT_DIR/prs.ndjson" > "$OUT_DIR/prs.json"
}

cmd_resolve() {
  need_env REPO SHA OUT_DIR ROLE
  case "$ROLE" in staging | production) ;; *) die "ROLE must be staging or production" ;; esac
  local main_ref="${MAIN_REF:-origin/$PROD_BRANCH}"
  mkdir -p "$OUT_DIR"; : > "$OUT_DIR/result.env"

  list_remote_tags > "$OUT_DIR/tags.txt"
  # ECR version tags (when the caller has them) count for the counter too, so a deleted git tag never frees a number
  if [ -n "${EXTRA_TAGS_FILE:-}" ] && [ -f "$EXTRA_TAGS_FILE" ]; then cat "$EXTRA_TAGS_FILE" >> "$OUT_DIR/tags.txt"; fi
  git tag --merged "$main_ref" > "$OUT_DIR/reachable_main.txt" 2>/dev/null || : > "$OUT_DIR/reachable_main.txt"

  gather_context
  local direct_n cls kind direct_push
  direct_n="$(grep -c . "$OUT_DIR/direct.txt" || true)"
  cls="$(cmd_classify --prs "$OUT_DIR/prs.json" --direct "$direct_n")"
  kind="$(printf '%s\n' "$cls" | sed -n 's/^kind=//p')"
  direct_push="$(printf '%s\n' "$cls" | sed -n 's/^direct_push=//p')"

  local version="" bump="" pending=false reused=false approximate=false existing nx
  existing="$(cmd_reuse --sha "$SHA" --tags "$OUT_DIR/tags.txt")"
  if [ -n "$existing" ]; then
    version="$(printf '%s\n' "$existing" | sed -n 's/^version=//p')"
    reused=true; bump=reuse
  elif [ "$ROLE" = staging ] || [ "$kind" = hotfix ]; then
    nx="$(cmd_next --kind "$kind" --tags "$OUT_DIR/tags.txt" --reachable "$OUT_DIR/reachable_main.txt")"
    version="$(printf '%s\n' "$nx" | sed -n 's/^version=//p')"
    bump="$(printf '%s\n' "$nx" | sed -n 's/^bump=//p')"
    pending=true
  elif [ -n "$BASE_TAG" ]; then
    # production build of a commit nobody versioned itself (the merge commit of staging -> main): it contains everything up to
    # the newest release reachable from it, so that release is the version it ships.
    version="${BASE_TAG#v}"; bump=reachable; approximate=true
  fi

  emit version "$version"
  emit tag "${version:+v$version}"
  emit kind "$kind"
  emit bump "$bump"
  emit reused "$reused"
  emit pending "$pending"
  emit approximate "$approximate"
  emit direct_push "$direct_push"
  emit previous "${BASE_TAG}"
  echo "version: ${version:-<none>} (role=$ROLE kind=$kind bump=$bump reused=$reused pending=$pending)" >&2
}

tag_commit() {  # tag_commit TAG -> commit sha the remote tag points at ("" if absent)
  list_remote_tags | awk -v t="$1" '$1 == t {print $2}' | head -n1
}

cmd_mint() {
  need_env REPO SHA OUT_DIR KIND VERSION
  local retries="${MINT_RETRIES:-5}" main_ref="${MAIN_REF:-origin/$PROD_BRANCH}" attempt final="" created=false bump="${BUMP:-release}" nx tag at
  mkdir -p "$OUT_DIR"; : > "$OUT_DIR/mint.env"
  for ((attempt = 1; attempt <= retries; attempt++)); do
    list_remote_tags > "$OUT_DIR/tags.txt"
    if [ -n "${EXTRA_TAGS_FILE:-}" ] && [ -f "$EXTRA_TAGS_FILE" ]; then cat "$EXTRA_TAGS_FILE" >> "$OUT_DIR/tags.txt"; fi
    git tag --merged "$main_ref" > "$OUT_DIR/reachable_main.txt" 2>/dev/null || : > "$OUT_DIR/reachable_main.txt"

    nx="$(cmd_reuse --sha "$SHA" --tags "$OUT_DIR/tags.txt")"
    if [ -n "$nx" ]; then final="$(printf '%s\n' "$nx" | sed -n 's/^version=//p')"; bump=reuse; break; fi

    nx="$(cmd_next --kind "$KIND" --tags "$OUT_DIR/tags.txt" --reachable "$OUT_DIR/reachable_main.txt")"
    final="$(printf '%s\n' "$nx" | sed -n 's/^version=//p')"
    bump="$(printf '%s\n' "$nx" | sed -n 's/^bump=//p')"
    tag="v$final"
    # Lightweight tag through the refs API: creating an existing ref is rejected (HTTP 422), which is the atomic "claim".
    if gh api -X POST "repos/$REPO/git/refs" -f "ref=refs/tags/$tag" -f "sha=$SHA" >/dev/null 2>"$OUT_DIR/mint.err"; then
      created=true; break
    fi
    at="$(tag_commit "$tag")"
    if [ "$at" = "$SHA" ]; then created=false; break; fi          # a sibling job (another service of this repo) just made it
    if [ -n "$at" ]; then
      echo "::notice::$tag was taken by another commit while this run was in flight; recomputing (attempt $attempt/$retries)" >&2
      final=""
      continue
    fi
    sed 's/^/  gh: /' "$OUT_DIR/mint.err" >&2
    die "could not create tag $tag (not a collision: check that the job has 'contents: write')"
  done
  [ -n "$final" ] || die "no free version after $retries attempts"

  local mismatch=false
  [ "$final" = "$VERSION" ] || mismatch=true
  [ "$mismatch" = false ] || echo "::warning::the image was built as $VERSION but $VERSION was taken meanwhile: released as $final. The running service still reports $VERSION." >&2

  cmd_notes --version "$final" --kind "$KIND" --bump "$bump" --sha "$SHA" --prs "$OUT_DIR/prs.json" --direct "$OUT_DIR/direct.txt" \
    --previous "${PREVIOUS:-}" --repo "$REPO" > "$OUT_DIR/notes.md"
  if ! gh release view "v$final" >/dev/null 2>&1; then
    gh release create "v$final" --verify-tag --title "v$final" --notes-file "$OUT_DIR/notes.md" >/dev/null
  fi
  printf 'version=%s\ncreated=%s\nmismatch=%s\n' "$final" "$created" "$mismatch" > "$OUT_DIR/mint.env"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then cat "$OUT_DIR/mint.env" >> "$GITHUB_OUTPUT"; fi
  echo "released v$final (new tag: $created)" >&2
}

# ===================================================================================================================
main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    next) cmd_next "$@" ;;
    classify) cmd_classify "$@" ;;
    normalize) cmd_normalize "$@" ;;
    reuse) cmd_reuse "$@" ;;
    highest) cmd_highest "$@" ;;
    notes) cmd_notes "$@" ;;
    resolve) cmd_resolve ;;
    mint) cmd_mint ;;
    *) sed -n '2,32p' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
