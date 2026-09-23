#!/usr/bin/env python3
"""
Coverage gate: fail when line coverage is below a minimum. Vendor-neutral replacement for a SonarCloud quality gate.

Supported reports (all produced by free tools):
  jacoco    target/site/jacoco/jacoco.xml            (Maven + JaCoCo)
  cobertura coverage.xml                              (pytest-cov / coverage.py)
  lcov      coverage/lcov.info                        (c8 / vitest / nyc)

Usage: check_coverage.py --format jacoco --file target/site/jacoco/jacoco.xml --min 45 [--label backend]
Exit 1 when below the minimum or when the report is missing/empty (a missing report must not pass silently).
"""
import argparse
import os
import sys
import xml.etree.ElementTree as ET
from typing import Optional, Tuple


def parse_jacoco(path: str) -> Tuple[int, int]:
    root = ET.parse(path).getroot()
    for counter in root.findall("counter"):  # report-level totals are direct children of <report>
        if counter.get("type") == "LINE":
            missed, covered = int(counter.get("missed", 0)), int(counter.get("covered", 0))
            return covered, covered + missed
    raise ValueError("no report-level LINE counter in JaCoCo XML")


def parse_cobertura(path: str) -> Tuple[int, int]:
    root = ET.parse(path).getroot()
    valid, covered = root.get("lines-valid"), root.get("lines-covered")
    if valid is not None and covered is not None:
        return int(covered), int(valid)
    total = hit = 0
    for line in root.iter("line"):
        total += 1
        hit += 1 if int(line.get("hits", 0)) > 0 else 0
    return hit, total


def parse_lcov(path: str) -> Tuple[int, int]:
    found = hit = 0
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            if raw.startswith("LF:"):
                found += int(raw[3:])
            elif raw.startswith("LH:"):
                hit += int(raw[3:])
    return hit, found


PARSERS = {"jacoco": parse_jacoco, "cobertura": parse_cobertura, "lcov": parse_lcov}


def evaluate(fmt: str, path: str, minimum: float) -> Tuple[bool, float, int, int]:
    covered, total = PARSERS[fmt](path)
    if total == 0:
        raise ValueError("report contains zero executable lines")
    pct = 100.0 * covered / total
    return pct + 1e-9 >= minimum, pct, covered, total


def main(argv: Optional[list] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--format", required=True, choices=sorted(PARSERS))
    ap.add_argument("--file", required=True)
    ap.add_argument("--min", type=float, required=True, help="minimum line coverage percent")
    ap.add_argument("--label", default="")
    args = ap.parse_args(argv)

    if not os.path.isfile(args.file):
        print(f"::error::coverage report not found: {args.file} (tests did not run or the report step is misconfigured)")
        return 1
    try:
        ok, pct, covered, total = evaluate(args.format, args.file, args.min)
    except (ET.ParseError, ValueError) as e:
        print(f"::error::cannot read coverage report {args.file}: {e}")
        return 1

    status = "PASS" if ok else "FAIL"
    line = f"Line coverage {args.label}: {pct:.1f}% ({covered}/{total} lines), minimum {args.min:.1f}% -> {status}"
    print(line)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(f"### Coverage {args.label}\n\n| Lines | Covered | Coverage | Minimum | Result |\n| --- | --- | --- | --- | --- |\n"
                     f"| {total} | {covered} | {pct:.1f}% | {args.min:.1f}% | {status} |\n\n")
    if not ok:
        print(f"::error::Line coverage {pct:.1f}% is below the required {args.min:.1f}%. Add tests for the new code.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
