#!/usr/bin/env bash
# Tests scripts/compute-version.sh: the pure version rules (no GitHub needed) and the git/gh glue against a real git history
# and a fake `gh`. Needs Linux (or macOS) with git and jq:
#   docker run --rm -v "$PWD/..:/r:ro" ubuntu:24.04 bash -c 'apt-get update -qq && apt-get install -y -qq git jq >/dev/null && bash /r/scripts/test_compute_version.sh'
# shellcheck disable=SC2317,SC2329,SC2034  # check()/field() are invoked through eval, and so are the variables the checks read
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CV="$ROOT/scripts/compute-version.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail=0; n=0
check() { n=$((n + 1)); if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }
field() { sed -n "s/^$1=//p" | head -n1; }   # field KEY < key=value lines

# ---------- pure core: next ----------------------------------------------------------------------------------------------
nx() {  # nx KIND "tags (space separated)" ["reachable tags"]  -> key=value lines
  # shellcheck disable=SC2086  # the tag lists are space separated on purpose
  printf '%s\n' $2 > "$WORK/t.txt"
  # shellcheck disable=SC2086
  printf '%s\n' ${3:-} > "$WORK/r.txt"
  bash "$CV" next --kind "$1" --tags "$WORK/t.txt" --reachable "$WORK/r.txt"
}
ver() { nx "$@" | field version; }

check "first version of a repo without tags is 1.1.0 (every kind)" \
  "[ \"\$(ver staging-pr '')\" = 1.1.0 ] && [ \"\$(ver direct-push '')\" = 1.1.0 ] && [ \"\$(ver hotfix '')\" = 1.1.0 ] && [ \"\$(ver breaking '')\" = 1.1.0 ]"
check "seed is reported as bump=seed" "[ \"\$(nx staging-pr '' | field bump)\" = seed ]"
check "merged staging PR: RELEASE + 1" "[ \"\$(ver staging-pr 'v1.1.0')\" = 1.2.0 ]"
check "merged staging PR resets HOTFIX to 0" "[ \"\$(ver staging-pr 'v2.460.0 v2.460.3')\" = 2.461.0 ]"
check "compares numerically, not as text (2.10 > 2.9)" "[ \"\$(ver staging-pr 'v2.9.0 v2.10.0 v2.2.0')\" = 2.11.0 ]"
check "the order of the tag list does not matter" "[ \"\$(ver staging-pr 'v1.5.0 v3.1.0 v2.9.9')\" = 3.2.0 ]"
check "previous= reports the highest tag used as the base" "[ \"\$(nx staging-pr 'v1.5.0 v3.1.2' | field previous)\" = 3.1.2 ]"
check "direct push: RELEASE + 1 and flagged" "[ \"\$(ver direct-push 'v2.461.0')\" = 2.462.0 ] && [ \"\$(nx direct-push 'v2.461.0' | field direct_push)\" = true ]"
check "a normal PR is not flagged as direct push" "[ \"\$(nx staging-pr 'v2.461.0' | field direct_push)\" = false ]"
check "breaking: MAJOR + 1, RELEASE and HOTFIX 0" "[ \"\$(ver breaking 'v2.461.3')\" = 3.0.0 ]"
check "after a breaking release the next PR is 3.1.0" "[ \"\$(ver staging-pr 'v2.461.3 v3.0.0')\" = 3.1.0 ]"
check "hotfix: HOTFIX + 1 on the last prod release, not on the newest staging tag" \
  "[ \"\$(ver hotfix 'v2.461.0 v2.465.0' 'v2.461.0')\" = 2.461.1 ]"
check "hotfix never collides: v2.461.1 exists -> v2.461.2" "[ \"\$(ver hotfix 'v2.461.0 v2.461.1 v2.465.0' 'v2.461.0 v2.461.1')\" = 2.461.2 ]"
check "hotfix picks the next FREE patch even when a higher patch is not reachable from main" \
  "[ \"\$(ver hotfix 'v2.461.0 v2.461.1 v2.461.2 v2.465.0' 'v2.461.0')\" = 2.461.3 ]"
check "a hotfix when staging is not ahead" "[ \"\$(ver hotfix 'v2.461.0' 'v2.461.0')\" = 2.461.1 ]"
check "the release after a hotfix resets HOTFIX and bumps from the highest tag" "[ \"\$(ver staging-pr 'v2.461.0 v2.461.1 v2.465.0')\" = 2.466.0 ]"
check "the release after a hotfix on the newest line" "[ \"\$(ver staging-pr 'v2.461.0 v2.461.1')\" = 2.462.0 ]"
check "hotfix without any prod release reachable from main falls back to a normal release (flagged)" \
  "[ \"\$(ver hotfix 'v2.461.0' '')\" = 2.462.0 ] && [ \"\$(nx hotfix 'v2.461.0' '' | field hotfix_fallback)\" = true ]"
check "hotfix bump is reported as bump=hotfix" "[ \"\$(nx hotfix 'v2.461.0' 'v2.461.0' | field bump)\" = hotfix ]"
check "deleted tag cannot free its number: ECR still has v2.462.0 -> 2.463.0 (git tags and ECR tags are merged)" \
  "[ \"\$(ver staging-pr 'v2.460.0 v2.462.0')\" = 2.463.0 ]"
check "a hole left by a deleted tag is never refilled (v2.2.0 deleted)" "[ \"\$(ver staging-pr 'v2.1.0 v2.3.0')\" = 2.4.0 ]"
check "the deleted top tag is remembered through the ECR copy" "[ \"\$(ver staging-pr 'v2.1.0 v2.3.0 v2.7.0')\" = 2.8.0 ]"
check "prerelease tags are ignored (rc, beta, build metadata)" \
  "[ \"\$(ver staging-pr 'v9.0.0-rc1 v9.9.9-beta.2 v9.9.9+build5 v2.4.0')\" = 2.5.0 ]"
check "malformed tags are ignored (v2.5, v02.5.0, v2.5.0.1, 2.5.0, vfoo, v2.5.x, v-1.2.3, empty)" \
  "[ \"\$(ver staging-pr 'v2.5 v02.5.0 v2.5.0.1 2.5.0 vfoo v2.5.x v-1.2.3 v1.2.3.4 V9.9.9 v2.4.0')\" = 2.5.0 ]"
check "a repo with only junk tags is treated as unversioned (1.1.0)" "[ \"\$(ver staging-pr 'v1.0 latest v1.0.0-rc1')\" = 1.1.0 ]"
check "absurdly long numbers are rejected instead of overflowing" "[ \"\$(ver staging-pr 'v99999999999999999999.1.1 v2.4.0')\" = 2.5.0 ]"
check "refs/tags/ prefixes and a 'name sha' second column are accepted" "[ \"\$(ver staging-pr 'refs/tags/v2.4.0')\" = 2.5.0 ]"
printf 'v2.4.0 abc\r\nv1.0.0 def\r\n' > "$WORK/crlf.txt"
check "CRLF tag lists work" "[ \"\$(bash $CV next --kind staging-pr --tags $WORK/crlf.txt | field version)\" = 2.5.0 ]"
check "stdin works for the tags list" "[ \"\$(printf 'v3.2.1\n' | bash $CV next --kind breaking --tags - | field version)\" = 4.0.0 ]"
check "an unknown kind is refused" "! bash $CV next --kind nonsense --tags $WORK/t.txt >/dev/null 2>&1"
check "highest prints the highest valid version" "[ \"\$(printf 'v1.2.3\nv1.10.0\nv1.9.9\nvx\n' | bash $CV highest)\" = 1.10.0 ]"

# ---------- pure core: rerun reuse --------------------------------------------------------------------------------------
printf 'v1.1.0 aaa\nv1.2.0 bbb\nv1.2.1 bbb\nv1.2.1-rc1 ccc\nv1.3.0 ddd\n' > "$WORK/at.txt"
check "rerun reuses the tag already on the commit" "[ \"\$(bash $CV reuse --sha aaa --tags $WORK/at.txt | field version)\" = 1.1.0 ]"
check "several tags on one commit: the highest wins" "[ \"\$(bash $CV reuse --sha bbb --tags $WORK/at.txt | field version)\" = 1.2.1 ]"
check "a commit with only a prerelease tag has no version" "[ -z \"\$(bash $CV reuse --sha ccc --tags $WORK/at.txt)\" ]"
check "an unversioned commit has nothing to reuse" "[ -z \"\$(bash $CV reuse --sha zzz --tags $WORK/at.txt)\" ]"

# ---------- pure core: classify / normalize / notes ---------------------------------------------------------------------
pr_json() {  # pr_json NUMBER BASE HEAD LABELS(comma) [fork]
  local labels; labels="$(printf '%s\n' "$4" | jq -R 'split(",") | map(select(. != ""))')"
  jq -nc --argjson n "$1" --arg b "$2" --arg h "$3" --argjson l "$labels" --argjson f "${5:-false}" \
    '{number:$n,title:"Title \($n)",body:"",url:"u",author:"dev",base:$b,head:$h,fork:$f,labels:$l}'
}
cls() { local direct="$1"; shift; printf '%s\n' "$@" | jq -s . > "$WORK/p.json"; bash "$CV" classify --prs "$WORK/p.json" --direct "$direct" | field kind; }
check "classify: a PR into staging is a normal release" "[ \"\$(cls 0 \"\$(pr_json 1 staging feature/x '')\")\" = staging-pr ]"
check "classify: hotfix/* into main is a hotfix" "[ \"\$(cls 0 \"\$(pr_json 2 main hotfix/login '')\")\" = hotfix ]"
check "classify: hotfix/* into staging is NOT a hotfix" "[ \"\$(cls 0 \"\$(pr_json 3 staging hotfix/login '')\")\" = staging-pr ]"
check "classify: a feature branch into main is NOT a hotfix" "[ \"\$(cls 0 \"\$(pr_json 4 main feature/x '')\")\" = staging-pr ]"
check "classify: a hotfix/* branch from a fork is NOT a hotfix" "[ \"\$(cls 0 \"\$(pr_json 5 main hotfix/x '' true)\")\" = staging-pr ]"
check "classify: the breaking label wins" "[ \"\$(cls 0 \"\$(pr_json 6 staging feature/x 'breaking')\")\" = breaking ]"
check "classify: the breaking label wins over hotfix/* (case-insensitive)" "[ \"\$(cls 0 \"\$(pr_json 7 main hotfix/x 'Breaking,bug')\")\" = breaking ]"
check "classify: no PR at all is a direct push" "[ \"\$(cls 1)\" = direct-push ]"
check "classify: an empty batch (only promotion merges) is an ordinary release, not a direct push" "[ \"\$(cls 0)\" = staging-pr ] && [ \"\$(echo '[]' | bash $CV classify | field direct_push)\" = false ]"
check "classify: a hotfix batch with a direct commit is an ordinary release" "[ \"\$(cls 1 \"\$(pr_json 8 main hotfix/x '')\")\" = staging-pr ]"
check "classify: two PRs in one batch, one breaking -> breaking" "[ \"\$(cls 0 \"\$(pr_json 9 staging a '')\" \"\$(pr_json 10 staging b 'breaking')\")\" = breaking ]"
check "classify: direct_push flag is only for batches without any PR" \
  "[ \"\$(bash $CV classify --prs $WORK/p.json --direct 2 | field direct_push)\" = false ] && [ \"\$(echo '[]' | bash $CV classify --direct 2 | field direct_push)\" = true ]"

raw='[{"number":5,"title":"Add x","body":"b","html_url":"u5","user":{"login":"ann"},"base":{"ref":"staging","repo":{"full_name":"o/r"}},"head":{"ref":"feature/x","repo":{"full_name":"o/r"}},"merged_at":"2026-01-01T00:00:00Z","merge_commit_sha":"M1","labels":[{"name":"bug"}]},
      {"number":9,"title":"Promote","body":"","html_url":"u9","user":{"login":"bob"},"base":{"ref":"main","repo":{"full_name":"o/r"}},"head":{"ref":"staging","repo":{"full_name":"o/r"}},"merged_at":"2026-01-02T00:00:00Z","merge_commit_sha":"M9","labels":[]},
      {"number":7,"title":"Open","body":"","html_url":"u7","user":{"login":"cy"},"base":{"ref":"staging","repo":{"full_name":"o/r"}},"head":{"ref":"y","repo":{"full_name":"o/r"}},"merged_at":null,"merge_commit_sha":"M1","labels":[]}]'
norm="$(printf '%s' "$raw" | bash "$CV" normalize --sha M1)"
check "normalize keeps only the PR that merged exactly this commit (not the later promotion PR, not unmerged PRs)" \
  "[ \"\$(printf '%s' \"\$norm\" | jq 'length')\" = 1 ] && [ \"\$(printf '%s' \"\$norm\" | jq -r '.[0].number')\" = 5 ] && [ \"\$(printf '%s' \"\$norm\" | jq -r '.[0].labels[0]')\" = bug ]"
check "normalize records base/head/fork" "[ \"\$(printf '%s' \"\$norm\" | jq -r '.[0].base + \" \" + .[0].head + \" \" + (.[0].fork|tostring)')\" = 'staging feature/x false' ]"

jq -nc '[{number:12,title:"Fix @everyone login",body:"Cc @team <!-- template hint -->\nreal body",url:"u",author:"ann",base:"staging",head:"f",fork:false,labels:["bug"]}]' > "$WORK/np.json"
printf 'abc1234 hotfix pushed by @mallory\n' > "$WORK/nd.txt"
notes="$(bash "$CV" notes --version 2.462.0 --kind staging-pr --bump release --sha 0123456789abcdef --prs "$WORK/np.json" --direct "$WORK/nd.txt" --previous v2.461.0 --repo o/r)"
check "notes: version, short commit, PR number, title and body appear" "grep -q 'Version 2.462.0' <<<\"\$notes\" && grep -q '0123456789ab' <<<\"\$notes\" && grep -q '#12' <<<\"\$notes\" && grep -q 'real body' <<<\"\$notes\""
check "notes: PR template comments are dropped" "! grep -q 'template hint' <<<\"\$notes\""
check "notes: @mentions inside PR text cannot ping anyone" "! grep -q '@everyone' <<<\"\$notes\" && ! grep -q '@team' <<<\"\$notes\" && ! grep -q '@mallory' <<<\"\$notes\""
check "notes: direct pushes get their own flagged section" "grep -q 'Direct pushes (no pull request)' <<<\"\$notes\" && grep -q 'abc1234' <<<\"\$notes\""
check "notes: changelog link" "grep -q 'compare/v2.461.0...v2.462.0' <<<\"\$notes\""
echo '[]' > "$WORK/empty.json"
dnotes="$(bash "$CV" notes --version 2.462.0 --kind direct-push --bump release --prs "$WORK/empty.json" --direct "$WORK/nd.txt")"
check "notes: a direct push release says so in the headline" "grep -q 'DIRECT PUSH' <<<\"\$dnotes\""

# ---------- glue: real git history + fake gh ----------------------------------------------------------------------------
FAKE="$WORK/fake"; mkdir -p "$FAKE/bin" "$FAKE/pulls"
: > "$FAKE/tags"; : > "$FAKE/releases"; : > "$FAKE/log"
cat > "$FAKE/bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
echo "gh $*" >> "$FAKE/log"
args="$*"
case "$1" in
  api)
    case "$args" in
      *"-X POST"*"git/refs"*)
        if [ -n "${FAKE_DENY:-}" ]; then echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; fi
        ref=""; sha=""
        for a in "$@"; do case "$a" in ref=*) ref="${a#ref=}" ;; sha=*) sha="${a#sha=}" ;; esac; done
        if [ -s "$FAKE/race_once" ]; then cat "$FAKE/race_once" >> "$FAKE/tags"; : > "$FAKE/race_once"; fi
        name="${ref#refs/tags/}"
        if awk -v t="$name" '$1==t{f=1} END{exit !f}' "$FAKE/tags"; then echo "HTTP 422: Reference already exists" >&2; exit 1; fi
        echo "$name $sha" >> "$FAKE/tags"; echo '{}' ;;
      *"matching-refs/tags/v"*)
        jq -Rn '[inputs | select(length>0) | split(" ") | {ref: ("refs/tags/" + .[0]), object: {sha: .[1]}}]' < "$FAKE/tags" ;;
      *"/commits/"*"/pulls"*)
        sha="${args#*commits/}"; sha="${sha%%/pulls*}"
        if [ -f "$FAKE/pulls/$sha.json" ]; then cat "$FAKE/pulls/$sha.json"; else echo '[]'; fi ;;
      *) echo "fake gh: unhandled api call: $args" >&2; exit 2 ;;
    esac ;;
  release)
    case "$2" in
      view) grep -qx "$3" "$FAKE/releases" ;;
      create) tag="$3"; echo "$tag" >> "$FAKE/releases"
              while [ $# -gt 0 ]; do if [ "$1" = --notes-file ]; then cp "$2" "$FAKE/notes_$tag.md"; fi; shift; done ;;
    esac ;;
esac
FAKEGH
chmod +x "$FAKE/bin/gh"; export PATH="$FAKE/bin:$PATH" FAKE

REPO_DIR="$WORK/repo"; mkdir -p "$REPO_DIR"; cd "$REPO_DIR" || exit 1
git init -q -b main; git config user.email t@t; git config user.name t
commit() { echo "$1" > "f_$1"; git add "f_$1"; git commit -qm "$1"; git rev-parse HEAD; }
merge() {  # merge BRANCH INTO : a merge commit, printed sha
  git checkout -q "$2"; git merge -q --no-ff -m "Merge $1 into $2" "$1"; git rev-parse HEAD
}
raw_pr() {  # raw_pr MERGE_SHA NUMBER TITLE BASE HEAD [LABEL]
  jq -nc --arg m "$1" --argjson n "$2" --arg t "$3" --arg b "$4" --arg h "$5" --arg l "${6:-}" \
    '[{number:$n,title:$t,body:"body of \($n)",html_url:"u",user:{login:"dev"},base:{ref:$b,repo:{full_name:"o/r"}},head:{ref:$h,repo:{full_name:"o/r"}},merged_at:"2026-01-01T00:00:00Z",merge_commit_sha:$m,labels:(if $l=="" then [] else [{name:$l}] end)}]' > "$FAKE/pulls/$1.json"
}
export REPO=o/r GH_TOKEN=x MAIN_REF=main
res() { OUT_DIR="$WORK/o$1" SHA="$2" ROLE="$3" bash "$CV" resolve 2>/dev/null; sed -n "s/^$4=//p" "$WORK/o$1/result.env"; }
rd() { sed -n "s/^$2=//p" "$WORK/o$1/result.env"; }  # rd OUTNAME KEY
mint() {  # mint OUTNAME SHA KIND VERSION
  OUT_DIR="$WORK/o$1" SHA="$2" KIND="$3" VERSION="$4" bash "$CV" mint 2>"$WORK/mint.err"
}

base=$(commit init); git checkout -q -b staging
git checkout -q -b feature/a staging; commit a >/dev/null; M1=$(merge feature/a staging); raw_pr "$M1" 1 "Add A" staging feature/a

res 1 "$M1" staging version >/dev/null
check "glue: a repo without tags gets 1.1.0 for its first PR merge, pending" "[ \"\$(rd 1 version)\" = 1.1.0 ] && [ \"\$(rd 1 pending)\" = true ] && [ \"\$(rd 1 kind)\" = staging-pr ]"
check "glue: resolve creates nothing (no tag, no release)" "[ ! -s $FAKE/tags ] && [ ! -s $FAKE/releases ]"
mint 1 "$M1" staging-pr 1.1.0; rc=$?
check "glue: mint creates the tag on the commit and one GitHub Release" "[ $rc -eq 0 ] && grep -qx \"v1.1.0 $M1\" $FAKE/tags && grep -qx v1.1.0 $FAKE/releases"
check "glue: the release notes carry the PR title and body" "grep -q 'Add A' $FAKE/notes_v1.1.0.md && grep -q 'body of 1' $FAKE/notes_v1.1.0.md"
git tag v1.1.0 "$M1"   # the workflow checkout has the tags (fetch-depth 0); mirror the remote ones
res 2 "$M1" staging version >/dev/null
check "glue: a rerun on the already versioned commit REUSES v1.1.0 (nothing pending)" "[ \"\$(rd 2 version)\" = 1.1.0 ] && [ \"\$(rd 2 reused)\" = true ] && [ \"\$(rd 2 pending)\" = false ]"
before=$(wc -l < "$FAKE/tags")
mint 2 "$M1" staging-pr 1.1.0; rc=$?
check "glue: a mint rerun creates no second tag and no second release" "[ $rc -eq 0 ] && [ \$(wc -l < $FAKE/tags) -eq $before ] && [ \$(grep -c v1.1.0 $FAKE/releases) -eq 1 ]"

git checkout -q -b feature/b staging; commit b >/dev/null; M2=$(merge feature/b staging); raw_pr "$M2" 2 "Add B" staging feature/b
res 3 "$M2" staging version >/dev/null
check "glue: the next PR merge is 1.2.0" "[ \"\$(rd 3 version)\" = 1.2.0 ] && [ \"\$(rd 3 previous)\" = v1.1.0 ]"
mint 3 "$M2" staging-pr 1.2.0; git tag v1.2.0 "$M2"

# several PRs merged while a run was queued: ONE version covers the whole batch
git checkout -q -b feature/c staging; commit c >/dev/null; M3=$(merge feature/c staging); raw_pr "$M3" 3 "Add C" staging feature/c
git checkout -q -b feature/d staging; commit d >/dev/null; M4=$(merge feature/d staging); raw_pr "$M4" 4 "Add D" staging feature/d
res 4 "$M4" staging version >/dev/null
check "glue: PRs merged while a run was queued share ONE version (1.3.0) ..." "[ \"\$(rd 4 version)\" = 1.3.0 ] && [ \"\$(jq length $WORK/o4/prs.json)\" = 2 ]"
mint 4 "$M4" staging-pr 1.3.0; git tag v1.3.0 "$M4"
check "glue: ... and the release notes list every PR of the batch" "grep -q 'Add C' $FAKE/notes_v1.3.0.md && grep -q 'Add D' $FAKE/notes_v1.3.0.md"
check "glue: the batch stays one release (no extra tags)" "! grep -q '^v1.4.0' $FAKE/tags"

# a direct push without PR
D1=$(commit direct-fix)
res 5 "$D1" staging version >/dev/null
check "glue: a direct push gets RELEASE+1 and is flagged" "[ \"\$(rd 5 version)\" = 1.4.0 ] && [ \"\$(rd 5 kind)\" = direct-push ] && [ \"\$(rd 5 direct_push)\" = true ]"
mint 5 "$D1" direct-push 1.4.0; git tag v1.4.0 "$D1"
check "glue: the direct push release notes say so" "grep -q 'DIRECT PUSH' $FAKE/notes_v1.4.0.md && grep -q 'direct-fix' $FAKE/notes_v1.4.0.md"

# collision: another run takes the number between resolve and mint
git checkout -q -b feature/e staging; commit e >/dev/null; M5=$(merge feature/e staging); raw_pr "$M5" 5 "Add E" staging feature/e
res 6 "$M5" staging version >/dev/null
echo "v1.5.0 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" > "$FAKE/race_once"
mint 6 "$M5" staging-pr 1.5.0; rc=$?
check "glue: tag collision with another commit -> recompute and retry (1.6.0), image/version mismatch reported" \
  "[ $rc -eq 0 ] && grep -qx \"v1.6.0 $M5\" $FAKE/tags && [ \"\$(sed -n 's/^mismatch=//p' $WORK/o6/mint.env)\" = true ] && [ \"\$(sed -n 's/^version=//p' $WORK/o6/mint.env)\" = 1.6.0 ]"
git tag v1.6.0 "$M5"

# deleted git tag + ECR copy still remembered
git checkout -q -b feature/f staging; commit f >/dev/null; M6=$(merge feature/f staging); raw_pr "$M6" 6 "Add F" staging feature/f
printf 'v1.9.0\nv1.2.0\n' > "$WORK/ecr_tags.txt"
EXTRA_TAGS_FILE="$WORK/ecr_tags.txt" res 7 "$M6" staging version >/dev/null
check "glue: ECR version tags count for the counter (v1.9.0 only in ECR -> 1.10.0)" "[ \"\$(rd 7 version)\" = 1.10.0 ]"

# failures that are not collisions do not loop
git checkout -q -b feature/g staging; commit g >/dev/null; M7=$(merge feature/g staging); raw_pr "$M7" 7 "Add G" staging feature/g
res 8 "$M7" staging version >/dev/null
: > "$FAKE/log"
FAKE_DENY=1 mint 8 "$M7" staging-pr "$(rd 8 version)"; rc=$?
check "glue: a permission error fails fast with a hint (not retried like a collision)" "[ $rc -ne 0 ] && grep -q 'contents: write' $WORK/mint.err && [ \$(grep -c 'git/refs' $FAKE/log) -eq 1 ]"

# breaking label
git checkout -q -b feature/h staging; commit h >/dev/null; M8=$(merge feature/h staging); raw_pr "$M8" 8 "Rework API" staging feature/h breaking
res 9 "$M8" staging version >/dev/null
check "glue: the breaking label makes the next version MAJOR+1.0.0 (2.0.0)" "[ \"\$(rd 9 version)\" = 2.0.0 ] && [ \"\$(rd 9 kind)\" = breaking ]"

# hotfix: main carries the last prod release (v1.2.0 at M2), staging is ahead
git checkout -q main; git merge -q --ff-only "$M2"; git tag -f v1.2.0 "$M2" >/dev/null
git checkout -q -b hotfix/crash main; HC=$(commit hotfix-crash); HM=$(merge hotfix/crash main); raw_pr "$HM" 20 "Fix crash" main hotfix/crash
res 10 "$HM" staging version >/dev/null
check "glue: hotfix PR into main = HOTFIX+1 of the last prod release (1.2.1), although staging is at 1.6.0" "[ \"\$(rd 10 version)\" = 1.2.1 ] && [ \"\$(rd 10 kind)\" = hotfix ] && [ \"\$(rd 10 pending)\" = true ]"
mint 10 "$HM" hotfix 1.2.1; git tag v1.2.1 "$HM"
check "glue: the hotfix tag is on the hotfix commit" "grep -qx \"v1.2.1 $HM\" $FAKE/tags"
git checkout -q -b hotfix/again main; commit hotfix-again >/dev/null; HM2=$(merge hotfix/again main); raw_pr "$HM2" 21 "Fix crash again" main hotfix/again
res 11 "$HM2" staging version >/dev/null
check "glue: a second hotfix takes the next free patch (1.2.2)" "[ \"\$(rd 11 version)\" = 1.2.2 ]"
mint 11 "$HM2" hotfix 1.2.2; git tag v1.2.2 "$HM2"

# production role (frontends build at prod time)
git checkout -q main; git merge -q --no-ff -m "Merge staging into main" "$M4" 2>/dev/null; PM=$(git rev-parse HEAD); raw_pr "$PM" 30 "Release" main staging
res 12 "$PM" production version >/dev/null
check "glue: production of an unversioned promotion commit ships the newest release reachable from it (not a new one)" \
  "[ \"\$(rd 12 version)\" = 1.3.0 ] && [ \"\$(rd 12 pending)\" = false ] && [ \"\$(rd 12 approximate)\" = true ]"
res 13 "$M4" production version >/dev/null
check "glue: the promotion PR (staging -> main) is not listed as a change" "[ \"\$(jq 'length' $WORK/o12/prs.json)\" = 0 ]"
check "glue: production of the exact staging commit reuses its tag" "[ \"\$(rd 13 version)\" = 1.3.0 ] && [ \"\$(rd 13 reused)\" = true ]"
git checkout -q -b hotfix/prodfix main; commit prodfix >/dev/null; HM3=$(merge hotfix/prodfix main); raw_pr "$HM3" 31 "Prod fix" main hotfix/prodfix
res 14 "$HM3" production version >/dev/null
check "glue: production of a hotfix PR merge mints a hotfix version (1.3.1)" "[ \"\$(rd 14 kind)\" = hotfix ] && [ \"\$(rd 14 pending)\" = true ] && [ \"\$(rd 14 version)\" = 1.3.1 ]"

echo; echo "$n checks"
exit $fail
