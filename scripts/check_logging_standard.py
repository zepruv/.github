#!/usr/bin/env python3
"""
Zepruv logging-standard gate for pull requests (see Backend/ZEPRUV_LOGGING_STANDARD.md).

Only the lines a PR ADDS are inspected, so legacy code never blocks a merge; new code must follow the standard.
Rules are deliberately small and mechanical (things a reviewer would otherwise catch by eye). Anything the
standard needs judgement for (event naming, business ids) is covered by tests in the service repos instead
(e.g. LogEventRegistryTest, LogbackJsonOutputTest).

Suppress one line with an inline comment that carries a reason:
    // logging-standard:ignore intentional console output for the CLI
    # logging-standard:ignore bootstrap message before logging is configured

Usage:
    check_logging_standard.py --profile java --base <sha> [--head <sha>]   # PR / push gate (added lines only)
    check_logging_standard.py --profile java --all --warn-only             # audit the whole tree, never fails

Exit code 1 if any ERROR-severity violation is found on an added line.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Callable, Dict, Iterable, List, Optional, Tuple

IGNORE_MARKER = "logging-standard:ignore"
SENSITIVE_WORDS = r"(?:password|passwd|secret|api[_-]?key|(?:access|refresh|auth|id)?[_-]?token|jwt|authorization|private[_-]?key|bearer)"
SAFE_WORDS = re.compile(r"mask|hash|redact|scrub|\*\*\*|\[REDACTED\]|is\s*(?:null|blank|empty)|length|present|configured", re.I)


@dataclass(frozen=True)
class Rule:
    id: str
    severity: str  # "error" | "warning"
    message: str
    check: Callable[[str], bool]  # True when the added line VIOLATES the rule


def _regex(pattern: str, flags: int = 0) -> Callable[[str], bool]:
    compiled = re.compile(pattern, flags)
    return lambda line: bool(compiled.search(line))


def _warn_error_only_message(line: str) -> bool:
    """log.warn/error(..., e.getMessage()) without also passing the exception (stack trace + error.* fields are lost)."""
    m = re.search(r"\blog\.(?:warn|error)\(.*?\b(\w+)\.getMessage\(\)\s*\)\s*;", line)
    return bool(m) and not re.search(r",\s*" + re.escape(m.group(1)) + r"\s*\)\s*;", line)


_STRING_LITERAL = re.compile(r"\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*'|`[^`]*`")


_FSTRING = re.compile(r"\bf([\"'])(.*?)\1")
_TEMPLATE = re.compile(r"`([^`]*)`")


def _code_only(text: str) -> str:
    """Drop string-literal contents: the words in message TEXT ("token refreshed") are fine, variables are not.
    Expressions embedded in Python f-strings ({x}) and JS template literals (${x}) are code, so they are kept."""
    text = _FSTRING.sub(lambda m: '"" ' + " ".join(re.findall(r"\{([^{}]*)\}", m.group(2))), text)
    text = _TEMPLATE.sub(lambda m: '"" ' + " ".join(re.findall(r"\$\{([^{}]*)\}", m.group(1))), text)
    return _STRING_LITERAL.sub('""', text)


def _logs_sensitive(call: str) -> Callable[[str], bool]:
    call_re = re.compile(call)
    word_re = re.compile(r"\b" + SENSITIVE_WORDS + r"\b", re.I)

    def check(line: str) -> bool:
        m = call_re.search(line)
        if not m:
            return False
        args = _code_only(line[m.start():])
        return bool(word_re.search(args)) and not SAFE_WORDS.search(args)

    return check


def _logs_raw_email(call: str) -> Callable[[str], bool]:
    call_re = re.compile(call)
    email_arg = re.compile(r"(?:,|\()\s*(?:[\w.]+\.)?(?:get)?(?:user|peer|host|candidate|to)?_?[Ee]mail(?:\(\))?\s*[,)]")

    def check(line: str) -> bool:
        m = call_re.search(line)
        if not m:
            return False
        args = _code_only(line[m.start():])
        return bool(email_arg.search(args)) and not SAFE_WORDS.search(args)

    return check


def _py_error_without_traceback(line: str) -> bool:
    """logger.error/warning(f"...{e}") inside an except: pass exc_info=True so error.type/stacktrace are recorded."""
    if not re.search(r"\blogger\.(?:error|warning)\(", line):
        return False
    if "exc_info" in line or "exception=" in line:
        return False
    return bool(re.search(r"\{(?:e|ex|exc|err|error)\}|\b(?:e|ex|exc|err)\b\s*\)\s*$|%s.*,\s*(?:e|ex|exc|err)\s*\)", line))


JAVA_RULES: List[Rule] = [
    Rule("JAVA001", "error", "System.out/err is not logging: use the class logger (structured JSON, levels, MDC).",
         _regex(r"\bSystem\.(?:out|err)\.print(?:ln|f)?\(")),
    Rule("JAVA002", "error", "printStackTrace() bypasses the JSON log format: pass the exception to log.error(msg, e).",
         _regex(r"\.printStackTrace\(\s*\)")),
    Rule("JAVA003", "error", "log.warn/error must pass the exception object, not only e.getMessage() (loses error.type, stack trace, stack hash).",
         _warn_error_only_message),
    Rule("JAVA004", "error", "Do not log secrets (password/token/api key/authorization). Log presence or a hash instead.",
         _logs_sensitive(r"\blog\.(?:trace|debug|info|warn|error)\(")),
    Rule("JAVA005", "error", "Do not log a raw email address: use MaskingUtils.hashIdentifier(email) (user.hash) or the numeric user id.",
         _logs_raw_email(r"\blog\.(?:trace|debug|info|warn|error)\(")),
    Rule("JAVA006", "warning", "Use {} placeholders instead of string concatenation in log calls (concatenation is built even when the level is off).",
         _regex(r"\blog\.(?:trace|debug|info|warn|error)\(\s*\"[^\"]*\"\s*\+")),
]

PY_RULES: List[Rule] = [
    Rule("PY001", "error", "print() is not logging: use the module logger so output is structured JSON with trace ids.",
         _regex(r"(?<![\w.])print\(")),
    Rule("PY002", "error", "logging.basicConfig() installs a plain-text formatter: use utils.logging.setup_logging / the service's JSON setup.",
         _regex(r"\blogging\.basicConfig\(")),
    Rule("PY003", "error", "logger.error/warning of an exception needs exc_info=True (records error.type and the stack trace).",
         _py_error_without_traceback),
    Rule("PY004", "error", "Do not log secrets (password/token/api key/authorization). Log presence or a hash instead.",
         _logs_sensitive(r"\blogger\.(?:debug|info|warning|error|exception|critical)\(")),
    Rule("PY005", "error", "Do not log a raw email address: use hash_identifier()/mask_email().",
         _logs_raw_email(r"\blogger\.(?:debug|info|warning|error|exception|critical)\(")),
]

NODE_RULES: List[Rule] = [
    Rule("JS001", "error", "console.* is not logging: use the service logger (structured JSON with trace ids).",
         _regex(r"(?<![\w.])console\.(?:log|info|warn|error|debug|trace)\(")),
    Rule("JS002", "error", "Do not log secrets (password/token/api key/authorization). Log presence or a hash instead.",
         _logs_sensitive(r"\blogger\.(?:debug|info|warn|error)\(")),
    Rule("JS003", "error", "Do not log a raw email address: hash it (logger.hashIdentifier) or log the user id.",
         _logs_raw_email(r"\blogger\.(?:debug|info|warn|error)\(")),
]

FRONTEND_RULES: List[Rule] = [
    Rule("FE001", "error", "Never write secrets or emails to the browser console (visible to anyone, and shipped to error reports).",
         _logs_sensitive(r"\bconsole\.(?:log|info|warn|error|debug)\(")),
    Rule("FE002", "warning", "Prefer telemetryService / the app logger over console.log for anything that should survive in production.",
         _regex(r"(?<![\w.])console\.log\(")),
]

PROFILES: Dict[str, Tuple[List[Rule], Callable[[str], bool]]] = {
    "java": (JAVA_RULES, lambda p: p.endswith(".java") and "/src/main/" in "/" + p),
    "python": (PY_RULES, lambda p: p.endswith(".py")),
    "node": (NODE_RULES, lambda p: p.endswith((".js", ".mjs", ".cjs", ".ts"))),
    "frontend": (FRONTEND_RULES, lambda p: p.endswith((".js", ".jsx", ".ts", ".tsx")) and "/src/" in "/" + p),
}

# Test code, fixtures, scripts and generated output are not production logging
EXCLUDED_PATH = re.compile(
    r"(^|/)(tests?|__tests__|spec|specs|fixtures|scripts|helpers|migrations|node_modules|dist|build|target|venv|\.venv|"
    r"docker-images|Competetive_Questions)/|(^|/)(test_[^/]*|[^/]*_test|conftest|[^/]*\.test|[^/]*\.spec)\.[a-z]+$"
)


@dataclass(frozen=True)
class Violation:
    path: str
    line: int
    rule: Rule
    text: str


def check_line(rules: Iterable[Rule], line: str) -> List[Rule]:
    if IGNORE_MARKER in line:
        return []
    return [r for r in rules if r.check(line)]


def added_lines(diff: str) -> Iterable[Tuple[str, int, str]]:
    """Yield (path, new_line_number, text) for every added line of a `git diff --unified=0` output."""
    path: Optional[str] = None
    new_line = 0
    for raw in diff.splitlines():
        if raw.startswith("+++ "):
            target = raw[4:].strip()
            path = None if target == "/dev/null" else target[2:] if target.startswith("b/") else target
        elif raw.startswith("@@"):
            m = re.search(r"\+(\d+)(?:,(\d+))?", raw)
            new_line = int(m.group(1)) if m else 0
        elif raw.startswith("+") and not raw.startswith("+++"):
            if path is not None:
                yield path, new_line, raw[1:]
            new_line += 1


def scan_added(diff: str, profile: str) -> List[Violation]:
    rules, wanted = PROFILES[profile]
    found: List[Violation] = []
    for path, line_no, text in added_lines(diff):
        if not wanted(path) or EXCLUDED_PATH.search(path):
            continue
        for rule in check_line(rules, text):
            found.append(Violation(path, line_no, rule, text.strip()))
    return found


def scan_tree(root: str, profile: str) -> List[Violation]:
    rules, wanted = PROFILES[profile]
    files = subprocess.run(["git", "ls-files"], cwd=root, capture_output=True, text=True, check=True).stdout.splitlines()
    found: List[Violation] = []
    for rel in files:
        if not wanted(rel) or EXCLUDED_PATH.search(rel):
            continue
        try:
            with open(os.path.join(root, rel), encoding="utf-8", errors="ignore") as fh:
                for i, text in enumerate(fh, start=1):
                    for rule in check_line(rules, text):
                        found.append(Violation(rel, i, rule, text.strip()))
        except OSError:
            continue
    return found


def git_diff(base: str, head: str, cwd: str) -> str:
    return subprocess.run(
        ["git", "diff", "--unified=0", "--no-color", "--diff-filter=AM", f"{base}...{head}"],
        cwd=cwd, capture_output=True, text=True, check=True,
    ).stdout


def report(violations: List[Violation]) -> None:
    for v in violations:
        level = "error" if v.rule.severity == "error" else "warning"
        print(f"::{level} file={v.path},line={v.line},title={v.rule.id}::{v.rule.message}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    lines = ["### Logging standard", ""]
    if not violations:
        lines.append("No violations on added lines.")
    else:
        lines += ["| Rule | Severity | Location | Line |", "| --- | --- | --- | --- |"]
        lines += [f"| {v.rule.id} | {v.rule.severity} | `{v.path}:{v.line}` | `{v.text[:90].replace('|', '/')}` |" for v in violations]
        lines += ["", "Standard: `Backend/ZEPRUV_LOGGING_STANDARD.md`. To suppress one line, add "
                      f"`{IGNORE_MARKER} <reason>` as a comment on it."]
    text = "\n".join(lines) + "\n"
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(text)
    else:
        print(text)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--profile", required=True, choices=sorted(PROFILES))
    parser.add_argument("--base", help="base commit (PR base / push 'before')")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--all", action="store_true", help="audit the whole tree instead of the diff")
    parser.add_argument("--warn-only", action="store_true", help="report but always exit 0")
    parser.add_argument("--repo", default=".")
    args = parser.parse_args(argv)

    if args.all:
        violations = scan_tree(args.repo, args.profile)
    else:
        base = args.base
        if not base or set(base) == {"0"}:  # first push of a branch: compare with the parent commit
            base = "HEAD~1"
        try:
            violations = scan_added(git_diff(base, args.head, args.repo), args.profile)
        except subprocess.CalledProcessError as e:
            print(f"::warning::could not diff {base}...{args.head}: {e.stderr.strip()}; scanning the tree instead")
            violations = scan_tree(args.repo, args.profile)

    report(violations)
    errors = [v for v in violations if v.rule.severity == "error"]
    print(f"logging-standard: {len(errors)} error(s), {len(violations) - len(errors)} warning(s)")
    return 0 if args.warn_only or not errors else 1


if __name__ == "__main__":
    sys.exit(main())
