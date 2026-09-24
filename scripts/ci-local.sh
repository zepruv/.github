#!/usr/bin/env bash
# Run a service's CI gates on your machine, the way the reusable workflows run them on GitHub.
#
#   cd <service repo> && /path/to/.github/scripts/ci-local.sh [--base REF] [--only a,b] [--skip a,b] [--keep]
#
# Settings (service name, test dir, coverage floor, Dockerfile, ...) are read from the `ci:` job of the repo's own
# .github/workflows/deploy.yml (or pr.yml), so they cannot drift from what CI actually uses.
#
# Every gate runs in a COPY of the repo that contains only what git would commit (tracked + untracked-not-ignored).
# That is deliberate: a local .env, logs/, caches or a venv make tests behave differently on your machine than in CI
# (a coverage floor that passed locally and failed in CI was exactly this).
#
# Gates: logging | ruff | tests | gitleaks | semgrep | trivy-fs | docker
# Needs: git, python3, uv (https://docs.astral.sh/uv), docker, trivy. Tool versions below match the workflows;
# keep them in sync with ci-python.yml / security.yml.
set -uo pipefail

RUFF_VERSION=0.16.8
SEMGREP_VERSION=1.177.0
GITLEAKS_VERSION=8.24.0
ALL_GATES="logging ruff tests gitleaks semgrep trivy-fs docker"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$PWD"; BASE=""; ONLY=""; SKIP=""; KEEP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    --skip) SKIP="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done

cd "$REPO" || exit 2
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "not a git repository: $REPO" >&2; exit 2; }
REPO="$(git rev-parse --show-toplevel)"; cd "$REPO"

selected() {  # selected <gate>: honours --only / --skip
  if [ -n "$ONLY" ]; then case ",$ONLY," in *",$1,"*) ;; *) return 1 ;; esac; fi
  case ",$SKIP," in *",$1,"*) return 1 ;; esac
  return 0
}

# ---- read the caller's CI settings ----
SETTINGS="$(uvx --quiet --with pyyaml python - "$REPO" <<'PY'
import glob, os, re, shlex, sys, yaml
repo = sys.argv[1]
files = sorted(glob.glob(os.path.join(repo, ".github/workflows/*.yml")), key=lambda f: (os.path.basename(f) != "deploy.yml", f))
for f in files:
    for name, job in ((yaml.safe_load(open(f)) or {}).get("jobs") or {}).items():
        m = re.search(r"ci-(python|node|java)\.yml", str(job.get("uses", "")))
        if m:
            w = job.get("with") or {}
            d = {"profile": m.group(1), "service_name": w.get("service_name", "service"),
                 "working_directory": w.get("working_directory", "."), "test_directory": w.get("test_directory", ""),
                 "python_version": str(w.get("python_version", "3.12")), "requirements": w.get("requirements", "requirements.txt"),
                 "run_tests": str(w.get("run_tests", True)).lower(), "pytest_args": w.get("pytest_args", ""),
                 "coverage_source": w.get("coverage_source", "app"), "coverage_min": w.get("coverage_min", 30),
                 "ruff_select": w.get("ruff_select", "F821,F811,F823,E9"), "docker_scan": str(w.get("docker_scan", True)).lower(),
                 "dockerfile": w.get("dockerfile", "Dockerfile"), "source": os.path.relpath(f, repo)}
            for k, v in d.items():
                print(f"CI_{k.upper()}={shlex.quote(str(v))}")
            sys.exit(0)
sys.exit("no job using ci-python/ci-node/ci-java.yml found in .github/workflows")
PY
)" || { echo "could not read CI settings from .github/workflows (is this a service repo?)" >&2; exit 2; }
eval "$SETTINGS"

TESTDIR="${CI_TEST_DIRECTORY:-}"; [ -n "$TESTDIR" ] || TESTDIR="$CI_WORKING_DIRECTORY"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ci-local.XXXXXX")"
cleanup() { [ "$KEEP" -eq 1 ] && echo "kept: $TMP" || rm -rf "$TMP"; }
trap cleanup EXIT

echo "== $CI_SERVICE_NAME ($CI_PROFILE) - settings from $CI_SOURCE =="

# ---- CI-like copy: only what git would commit ----
COPY="$TMP/tree"; mkdir -p "$COPY"
git ls-files -z -co --exclude-standard | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
  | rsync -a --from0 --files-from=- "$REPO/" "$COPY/"
echo "   copy of $(find "$COPY" -type f | wc -l | tr -d ' ') git-visible files (no .env, no ignored files)"

NAMES=(); RESULTS=(); NOTES=()
record() { NAMES+=("$1"); RESULTS+=("$2"); NOTES+=("$3"); }
LOGDIR="$TMP/logs"; mkdir -p "$LOGDIR"

run_gate() {  # run_gate <name> <function>: output to a log; show its tail only on failure
  local name="$1" fn="$2" log="$LOGDIR/$1.log" note rc
  selected "$name" || { record "$name" SKIP "not selected"; return; }
  printf '\n-- %s --\n' "$name"
  note="$($fn >"$log" 2>&1; echo "rc=$?")"; rc="${note##*rc=}"
  note="$(grep -v '^[[:space:]]*$' "$log" 2>/dev/null | tail -n 1 | perl -pe 's/\e\[[0-9;]*m//g' | cut -c1-110)"
  if [ "$rc" = "0" ]; then record "$name" PASS "$note"; echo "   PASS  $note"
  elif [ "$rc" = "77" ]; then record "$name" SKIP "$note"; echo "   SKIP  $note"
  else record "$name" FAIL "$note"; echo "   FAIL"; tail -n 60 "$log" | sed 's/^/   | /'; fi
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "$1 is not installed ($2)"; return 1; }; }

# ---- gates ----
gate_logging() {
  local prof="$CI_PROFILE" base="$BASE"
  if [ -z "$base" ]; then git rev-parse --verify -q origin/staging >/dev/null && base=origin/staging || base=HEAD; fi
  echo "added lines vs $base (uncommitted + new files included)"
  python3 - "$HERE" "$base" "$prof" <<'PY'
import subprocess, sys
sys.path.insert(0, sys.argv[1]); import check_logging_standard as c
base, prof = sys.argv[2], sys.argv[3]
run = lambda *a: subprocess.run(a, capture_output=True, text=True).stdout
diff = run("git", "diff", "--unified=0", "--no-color", "--diff-filter=AM", base)
for f in run("git", "ls-files", "--others", "--exclude-standard").split("\n"):
    if f: diff += run("git", "diff", "--no-index", "--unified=0", "--no-color", "/dev/null", f)
v = c.scan_added(diff, prof)
errs = [x for x in v if x.rule.severity == "error"]
for x in v: print(f"  {x.rule.id} {x.rule.severity} {x.path}:{x.line}: {x.text[:100]}")
print(f"logging-standard: {len(errs)} error(s), {len(v) - len(errs)} warning(s)")
sys.exit(1 if errs else 0)
PY
}

gate_ruff() {
  [ "$CI_PROFILE" = python ] || { echo "ruff gate is python-only"; return 77; }
  cd "$COPY/$TESTDIR" && uvx --quiet "ruff@$RUFF_VERSION" check --select "$CI_RUFF_SELECT" --output-format concise . && echo "ruff $RUFF_VERSION: all checks passed"
}

gate_tests() {
  [ "$CI_PROFILE" = python ] || { echo "tests gate is python-only in this script"; return 77; }
  [ "$CI_RUN_TESTS" = true ] || { echo "run_tests=false in the workflow"; return 77; }
  need uv "https://docs.astral.sh/uv" || return 1
  local req key venv f
  key="$(cd "$COPY/$TESTDIR" && for f in $CI_REQUIREMENTS; do cat "$f"; done | shasum | cut -c1-12)"
  venv="${XDG_CACHE_HOME:-$HOME/.cache}/zepruv-ci-local/$CI_SERVICE_NAME-py$CI_PYTHON_VERSION-$key"
  if [ ! -x "$venv/bin/python" ]; then
    echo "creating venv (python $CI_PYTHON_VERSION) - cached after the first run"
    uv venv -q --python "$CI_PYTHON_VERSION" "$venv" || return 1
    ( cd "$COPY/$TESTDIR" && args=""; for f in $CI_REQUIREMENTS; do args="$args -r $f"; done
      # shellcheck disable=SC2086
      uv pip install -q --python "$venv/bin/python" $args pytest pytest-cov ) || { rm -rf "$venv"; return 1; }
  fi
  cd "$COPY/$TESTDIR" || return 1
  # shellcheck disable=SC2086
  "$venv/bin/python" -m pytest -q -p no:cacheprovider --cov="$CI_COVERAGE_SOURCE" --cov-report=xml --cov-report=term $CI_PYTEST_ARGS || return 1
  python3 "$HERE/check_coverage.py" --format cobertura --file coverage.xml --min "$CI_COVERAGE_MIN" --label "$CI_SERVICE_NAME"
}

gate_gitleaks() {
  need docker "docker is needed to run gitleaks" || return 1
  docker run --rm -v "$COPY":/repo "zricethezav/gitleaks:v$GITLEAKS_VERSION" detect --source /repo --no-git --redact --no-banner 2>&1 | tail -n 5
  return "${PIPESTATUS[0]}"
}

gate_semgrep() {
  local packs="--config p/owasp-top-ten --config p/secrets --config p/dockerfile"
  case "$CI_PROFILE" in python) packs="$packs --config p/python" ;; node) packs="$packs --config p/nodejs --config p/javascript" ;; java) packs="$packs --config p/java" ;; esac
  cd "$COPY" || return 1
  # full scan of the copy, which is stricter than CI (CI only reports findings that are new since the base commit)
  # shellcheck disable=SC2086
  uvx --quiet "semgrep@$SEMGREP_VERSION" scan --error --severity ERROR --metrics off --disable-version-check $packs "$CI_WORKING_DIRECTORY" 2>&1 | tail -n 25
  local rc="${PIPESTATUS[0]}"; [ "$rc" = 0 ] && echo "semgrep $SEMGREP_VERSION: no blocking findings"; return "$rc"
}

gate_trivy_fs() {
  need trivy "brew install trivy" || return 1
  cd "$COPY" || return 1
  TRIVY_DETECTION_PRIORITY=comprehensive trivy fs --scanners vuln,secret,misconfig --severity CRITICAL,HIGH --ignore-unfixed \
    --skip-dirs node_modules,target,venv,.venv,dist,build --exit-code 1 -q "$CI_WORKING_DIRECTORY" 2>&1 | tail -n 40
  local rc="${PIPESTATUS[0]}"; [ "$rc" = 0 ] && echo "trivy fs: no CRITICAL/HIGH findings with a fix available"; return "$rc"
}

gate_docker() {
  [ "$CI_DOCKER_SCAN" = true ] || { echo "docker_scan=false in the workflow"; return 77; }
  need docker "docker is needed to build the image" || return 1; need trivy "brew install trivy" || return 1
  local tag="ci-local/$CI_SERVICE_NAME:$$" ctx="$COPY/$CI_WORKING_DIRECTORY"
  # full build output goes to the gate log so a failure shows pip's/apt's real error, not just "build failed"
  docker build --pull --progress=plain -t "$tag" -f "$ctx/$CI_DOCKERFILE" "$ctx" 2>&1 | grep -vE '^#[0-9]+ (DONE|CACHED|\[internal\]|sha256|transferring|exporting)' | tail -n 60
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "docker build failed (see the error above)"; return 1; }
  TRIVY_DETECTION_PRIORITY=comprehensive trivy image --scanners vuln --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1 -q "$tag" 2>&1 | tail -n 40
  local rc="${PIPESTATUS[0]}" nofix
  nofix="$(TRIVY_DETECTION_PRIORITY=comprehensive trivy image --scanners vuln --severity CRITICAL,HIGH -q -f json "$tag" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); v=[x for r in d.get("Results") or [] for x in r.get("Vulnerabilities") or []]; print(len(v), sum(1 for x in v if x["Severity"]=="CRITICAL"))' 2>/dev/null)"
  docker rmi "$tag" >/dev/null 2>&1
  [ "$rc" = 0 ] && echo "image scan: gate passes (CRITICAL+HIGH incl. no-fix, total/critical: ${nofix:-?} - ECR may still list these)"
  return "$rc"
}

for g in $ALL_GATES; do run_gate "$g" "gate_$(echo "$g" | tr - _)"; done

# ---- summary ----
echo; echo "== summary: $CI_SERVICE_NAME =="; fail=0
i=0; while [ "$i" -lt "${#NAMES[@]}" ]; do
  printf '  %-9s %-5s %s\n' "${NAMES[$i]}" "${RESULTS[$i]}" "${NOTES[$i]}"
  [ "${RESULTS[$i]}" = FAIL ] && fail=1; i=$((i + 1))
done
[ "$fail" -eq 0 ] && echo "all selected gates pass" || echo "FAILED - fix the gates above before pushing"
exit "$fail"
