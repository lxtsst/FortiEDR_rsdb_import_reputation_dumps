#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../rsdb_import_reputation_dumps.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

set_metadata_cursor() {
  LATEST_META_TYPE="$1"
  LATEST_META_FROM_DATE="$2"
  LATEST_META_DATE="$3"
  LATEST_META_PART="$4"
  LATEST_META_RANK="$(rank_for_type "$LATEST_META_TYPE")"
}

assert_covered() {
  local package="$1"
  covered_by_latest_metadata "$package" || fail "expected covered: $package"
}

assert_not_covered() {
  local package="$1"
  if covered_by_latest_metadata "$package"; then
    fail "expected not covered: $package"
  fi
}

set_metadata_cursor day 2026-06-04 2026-06-05 1
assert_covered "reputation-day-2026-06-04-part_part_1.zip"
assert_covered "reputation-day-2026-06-05-part_part_1.zip"
assert_not_covered "reputation-week-2026-06-10-part_part_1.zip"
assert_not_covered "reputation-full-2026-06-10-part_part_1.zip"

set_metadata_cursor week 2026-06-03 2026-06-10 1
assert_covered "reputation-day-2026-06-10-part_part_1.zip"
assert_not_covered "reputation-day-2026-06-11-part_part_1.zip"

echo "coverage logic checks passed"
