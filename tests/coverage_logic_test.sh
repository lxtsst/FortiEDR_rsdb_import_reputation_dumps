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

assert_file_size() {
  local expected="$1"
  local path="$2"
  local actual

  actual="$(file_size "$path")"
  [[ "$actual" == "$expected" ]] || fail "expected size $expected, got $actual: $path"
}

write_plan() {
  local plan_file="$1"
  shift
  local spec type date path rank

  : > "$plan_file"
  for spec in "$@"; do
    type="${spec%%:*}"
    date="${spec#*:}"
    path="$TEST_TMPDIR/reputation-${type}-${date}-part_part_1.zip"
    printf 'test payload for %s\n' "$spec" > "$path"
    rank="$(rank_for_type "$type")"
    printf '%s|%s|%010d|%s|%s|%s\n' "$rank" "$date" 1 "$type" 1 "$path" >> "$plan_file"
  done
}

set_metadata_cursor day 2026-06-04 2026-06-05 1
assert_not_covered "reputation-day-2026-06-04-part_part_1.zip"
assert_covered "reputation-day-2026-06-05-part_part_1.zip"
assert_not_covered "reputation-week-2026-06-10-part_part_1.zip"
assert_not_covered "reputation-full-2026-06-10-part_part_1.zip"

set_metadata_cursor week 2026-06-03 2026-06-10 1
assert_covered "reputation-day-2026-06-03-part_part_1.zip"
assert_covered "reputation-day-2026-06-10-part_part_1.zip"
assert_not_covered "reputation-day-2026-06-11-part_part_1.zip"

set_latest_metadata_cursor_from_output 'Most recent dump: Dump metadata. type: week from: 2026-07-18 08:00:00 to:2026-07-24 08:00:00 partNum: 1 Is last part:true'
[[ "$LATEST_META_TYPE" == "week" ]] || fail 'expected parsed weekly metadata type'
[[ "$LATEST_META_FROM_DATE" == "2026-07-18" ]] || fail 'expected parsed weekly metadata start date'
[[ "$LATEST_META_DATE" == "2026-07-24" ]] || fail 'expected parsed weekly metadata end date'
assert_covered "reputation-day-2026-07-18-part_part_1.zip"
assert_covered "reputation-day-2026-07-24-part_part_1.zip"
assert_not_covered "reputation-day-2026-07-25-part_part_1.zip"

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT
STATE_FILE="$TEST_TMPDIR/imported_dumps.tsv"
CLI_LOG="$TEST_TMPDIR/reputationdb.log"
TEST_DUMP="$TEST_TMPDIR/reputation-week-2026-07-15-part_part_1.zip"
printf 'new-payload' > "$TEST_DUMP"
TEST_DUMP_BASE="$(basename "$TEST_DUMP")"
TEST_DUMP_SIZE="$(file_size "$TEST_DUMP")"
assert_file_size 11 "$TEST_DUMP"

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

RUNTIME_WORKDIR="$TEST_TMPDIR/runtime_workdir"
RUNTIME_LOG_DIR="$TEST_TMPDIR/runtime_logs"
RUNTIME_STATE_FILE="$TEST_TMPDIR/runtime_state.tsv"
RUNTIME_WEEK_DUMP="$TEST_TMPDIR/reputation-week-2026-07-24-part_part_1.zip"
RUNTIME_DAY_DUMP="$TEST_TMPDIR/reputation-day-2026-07-24-part_part_1.zip"
mkdir -p "$RUNTIME_WORKDIR" "$RUNTIME_LOG_DIR"
printf 'weekly test payload\n' > "$RUNTIME_WEEK_DUMP"
printf 'daily test payload\n' > "$RUNTIME_DAY_DUMP"

assert_no_load_running() { :; }
cleanup_workdir_temp() { :; }
check_filesystem_space() { :; }
check_workdir_space_for_dump() { :; }
reputationdb() {
  case "$1" in
    last-dump-metadata)
      printf '%s\n' "$MOCK_LATEST_METADATA"
      ;;
    load-dump)
      printf 'Load dump successfully\n'
      ;;
    *)
      fail "unexpected mocked reputationdb command: $*"
      ;;
  esac
}

WORKDIR="$RUNTIME_WORKDIR"
RUN_LOG_DIR="$RUNTIME_LOG_DIR"
STATE_FILE="$RUNTIME_STATE_FILE"
touch "$STATE_FILE"
MOCK_LATEST_METADATA='Most recent dump: Dump metadata. type: week from: 2026-07-18 08:00:00 to:2026-07-24 08:00:00 partNum: 1 Is last part:true'
clear_latest_metadata_cursor
import_one week 2026-07-24 1 "$RUNTIME_WEEK_DUMP"
assert_covered "reputation-day-2026-07-24-part_part_1.zip"
import_one day 2026-07-24 1 "$RUNTIME_DAY_DUMP"
if compgen -G "$RUNTIME_LOG_DIR/day_2026-07-24_part_1_*.log" > /dev/null; then
  fail 'a day dump covered by the refreshed weekly metadata must not call load-dump'
fi
assert_imported_path "$RUNTIME_DAY_DUMP"
awk -F '\t' -v b="$(basename "$RUNTIME_DAY_DUMP")" '$2 == b && $4 == "metadata_coverage" { found=1 } END { exit found ? 0 : 1 }' "$RUNTIME_STATE_FILE" || fail 'expected a metadata-coverage state record for the skipped day dump'
set_metadata_cursor day 2026-07-24 2026-07-25 1
assert_imported_path "$RUNTIME_DAY_DUMP"

PLAN_FILE="$TEST_TMPDIR/import_plan.tsv"
set_metadata_cursor day 2026-07-14 2026-07-15 1
write_plan "$PLAN_FILE" \
  week:2026-07-19 week:2026-07-24 week:2026-07-31 week:2026-08-07 week:2026-08-12 \
  day:2026-08-12 day:2026-08-13 day:2026-08-14 day:2026-08-15 day:2026-08-16 day:2026-08-17
assert_exit_status 0 validate_incremental_coverage "$PLAN_FILE"

set_metadata_cursor day 2026-07-14 2026-07-15 1
write_plan "$PLAN_FILE" week:2026-07-19 day:2026-07-20 week:2026-07-24
assert_exit_status 0 validate_incremental_coverage "$PLAN_FILE"

ORDER_DIR="$TEST_TMPDIR/discovery_order"
mkdir -p "$ORDER_DIR"
touch "$ORDER_DIR/reputation-week-2026-07-19-part_part_1.zip"
touch "$ORDER_DIR/reputation-day-2026-07-20-part_part_1.zip"
touch "$ORDER_DIR/reputation-week-2026-07-24-part_part_1.zip"
SRC_DIR="$ORDER_DIR"
DISCOVERY_ORDER="$(discover_files | awk -F '|' '{print $4 " " $2}' | paste -sd ',' -)"
[[ "$DISCOVERY_ORDER" == 'week 2026-07-19,day 2026-07-20,week 2026-07-24' ]] || fail "unexpected mixed incremental order: $DISCOVERY_ORDER"
SRC_DIR="/tmp"

write_plan "$PLAN_FILE" week:2026-08-12 day:2026-08-12 day:2026-08-13
clear_latest_metadata_cursor
has_new_week_on_date "$PLAN_FILE" 2026-08-12 || fail 'expected the dry-run plan to defer the same-date day dump until weekly metadata is refreshed'
if has_new_week_on_date "$PLAN_FILE" 2026-08-13; then
  fail 'a later day without a same-date weekly package must not be deferred'
fi

set_metadata_cursor day 2026-07-14 2026-07-15 1
write_plan "$PLAN_FILE" week:2026-07-24
assert_exit_status 1 validate_incremental_coverage "$PLAN_FILE"

set_metadata_cursor day 2026-08-11 2026-08-12 1
write_plan "$PLAN_FILE" day:2026-08-14
assert_exit_status 1 validate_incremental_coverage "$PLAN_FILE"

set_metadata_cursor day 2026-08-16 2026-08-17 1
write_plan "$PLAN_FILE" day:2026-08-13
assert_exit_status 2 validate_incremental_coverage "$PLAN_FILE"

set_metadata_cursor day 2026-07-14 2026-07-15 1
write_plan "$PLAN_FILE" week:2026-07-19 week:2026-07-29 day:2026-08-12
PREFIX_PLAN="$TEST_TMPDIR/import_prefix.tsv"
COVERAGE_GAP_ACTION=import-prefix
if ! resolve_incremental_coverage "$PLAN_FILE" "$PREFIX_PLAN" >/dev/null 2>&1; then
  fail 'expected import-prefix action to accept the verified prefix'
fi
[[ "$SELECTED_PLAN_FILE" == "$PREFIX_PLAN" ]] || fail 'expected prefix plan to be selected'
grep -q '|2026-07-19|.*|week|' "$PREFIX_PLAN" || fail 'expected verified weekly package in prefix plan'
if grep -qE '2026-07-29|2026-08-12' "$PREFIX_PLAN"; then
  fail 'gap package or later package must not be in prefix plan'
fi

MISSING_UPDATE_LOG="$TEST_TMPDIR/missing_update.log"
printf 'Failed to validate metadata: db is missing update to use this dump\n' > "$MISSING_UPDATE_LOG"
part_log_missing_update "$MISSING_UPDATE_LOG" || fail 'expected missing-update product error to be classified'
set_metadata_cursor day 2026-07-14 2026-07-15 1
RECOVERY_OUTPUT="$(report_missing_update 'reputation-day-2026-08-12-part_part_1.zip' "$MISSING_UPDATE_LOG" 2>&1)"
[[ "$RECOVERY_OUTPUT" == *'Failed to validate metadata: db is missing update to use this dump'* ]] || fail 'expected original product error in recovery output'
[[ "$RECOVERY_OUTPUT" == *'reputation-week-2026-07-22-part_part_*.zip'* ]] || fail 'expected weekly recovery checkpoint in output'
[[ "$RECOVERY_OUTPUT" == *'reputation-day-2026-07-16-part_part_*.zip'* ]] || fail 'expected daily recovery package in output'

echo "coverage logic checks passed"
