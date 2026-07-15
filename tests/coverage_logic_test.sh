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

assert_exit_status() {
  local expected="$1"
  shift
  local actual

  if "$@"; then
    actual=0
  else
    actual=$?
  fi

  [[ "$actual" -eq "$expected" ]] || fail "expected exit $expected, got $actual: $*"
}

assert_imported_path() {
  local path="$1"
  is_imported_path "$path" || fail "expected imported: $path"
}

assert_not_imported_path() {
  local path="$1"
  if is_imported_path "$path"; then
    fail "expected not imported: $path"
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

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT
STATE_FILE="$TEST_TMPDIR/imported_dumps.tsv"
CLI_LOG="$TEST_TMPDIR/reputationdb.log"
TEST_DUMP="$TEST_TMPDIR/reputation-week-2026-07-15-part_part_1.zip"
printf 'new-payload' > "$TEST_DUMP"
TEST_DUMP_BASE="$(basename "$TEST_DUMP")"
TEST_DUMP_SIZE="$(file_size "$TEST_DUMP")"

LATEST_META_RANK=""
LATEST_META_DATE=""
LATEST_META_FROM_DATE=""
LATEST_META_PART=""
LATEST_META_TYPE=""
# This historical success marker must not override current state or metadata.
printf 'Saving metadata Dump metadata. type: week from: 2026-07-08 08:00:00 to:2026-07-15 08:00:00 partNum: 1 \n' > "$CLI_LOG"
printf '2026-07-15 08:00:00 CST\t%s\t%s\tname_size_only\t/tmp/%s\n' "$TEST_DUMP_BASE" "$((TEST_DUMP_SIZE + 1))" "$TEST_DUMP_BASE" > "$STATE_FILE"

assert_exit_status 2 state_has_file "$TEST_DUMP"
assert_not_imported_path "$TEST_DUMP"

record_imported "$TEST_DUMP" > /dev/null
assert_exit_status 0 state_has_file "$TEST_DUMP"
assert_imported_path "$TEST_DUMP"

echo "coverage logic checks passed"
