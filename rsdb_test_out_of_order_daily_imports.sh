#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="/tmp"
WORKDIR="/tmp/rsdb_ramwork"
RUN_ROOT="/var/log/reputationdb/out_of_order_tests"
MODE="dry-run"
FIRST_DATE=""
SECOND_DATE=""
BACKFILL_DATE=""
RUN_DIR=""
RESULTS_FILE=""
AUDIT_FILE=""
declare -a PACKAGE_FILES=()
declare -a TEST_DATES=()

usage() {
  cat <<'USAGE'
Usage:
  /tmp/rsdb_test_out_of_order_daily_imports.sh \
    --first YYYY-MM-DD --second YYYY-MM-DD --backfill YYYY-MM-DD [--run]

Purpose:
  Characterize how this RSDB build handles a direct out-of-order daily dump
  sequence and a repeated import of the first package.

Safety:
  - Default mode is read-only preflight. Use --run to call reputationdb load-dump.
  - All three date-specific day packages must be present in /tmp, with complete parts.
  - Refuses to run if any test date already has a stored dump metadata row.
  - Stops at the first failed import; it will not run a later stage after a failed one.
  - Stores an evidence bundle under /var/log/reputationdb/out_of_order_tests/.

Example:
  /tmp/rsdb_test_out_of_order_daily_imports.sh \
    --first 2026-08-12 --second 2026-08-14 --backfill 2026-08-13

  /tmp/rsdb_test_out_of_order_daily_imports.sh \
    --first 2026-08-12 --second 2026-08-14 --backfill 2026-08-13 --run
USAGE
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T %Z')" "$*"
}

record_result() {
  local phase="$1"
  local date_value="$2"
  local check="$3"
  local status="$4"
  local detail="$5"

  printf '%s\t%s\t%s\t%s\t%s\n' "$phase" "$date_value" "$check" "$status" "$detail" >> "$RESULTS_FILE"
}

date_to_epoch() {
  date -u -d "$1" '+%s'
}

validate_date() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  date -u -d "$1" '+%F' >/dev/null 2>&1
}

extract_reputation_stats() {
  local stats_file="$1"
  awk '
    /^===================reputations===================/ { in_reputations=1; next }
    in_reputations && /^keyCount:/ {
      print $1 " " $2 " " $3 " " $4
      exit
    }
  ' "$stats_file"
}

finalize_audit() {
  local rc="$1"
  local status="PASS"

  [[ "$rc" -eq 0 ]] || status="FAILED_OR_BLOCKED"
  cat > "$AUDIT_FILE" <<EOF
# RSDB Out-of-Order Daily Import Test Audit

- Result: **$status**
- Mode: \`$MODE\`
- Started: $(head -n 1 "$RUN_DIR/started_at.txt" 2>/dev/null || true)
- Finished: $(date '+%F %T %Z')
- Test order: $FIRST_DATE -> $SECOND_DATE -> $BACKFILL_DATE -> duplicate $FIRST_DATE

## Scope

The test invokes the product CLI directly, rather than the normal importer,
so the exact ordering reaches \`reputationdb load-dump\`. It does not change the
normal importer state file.

The final duplicate stage records whether the product rejects or accepts the
repeated package. Neither result alone proves the content-level effect of a
second load; use the normal importer for operational updates.

## Verification standard

A package stage is accepted only when every part exits with status 0, contains
\`Load dump successfully\`, and RSDB stores its matching \`dumps\` metadata row
under \`mt#<UTC-date-epoch>\`. The metadata row is a direct RocksDB record and
includes the dump type, end time, part number, and package file count.

The database does not expose per-dump provenance for every reputation row.
Therefore this audit does not claim that a sampled IOC belongs to a particular
package. The per-package loader result and the persisted \`dumps\` record are
the direct evidence of acceptance and metadata commit; \`db-stats\` snapshots
are supporting evidence only because an update may overwrite an existing key.

## Evidence files

- \`manifest.tsv\`: package filenames, sizes, and SHA-256 values captured before import.
- \`results.tsv\`: machine-readable checks and stage outcomes.
- \`snapshots/\`: metadata, internal \`dumps\` rows, database statistics, and process snapshots.
- \`imports/\`: exact command output for every imported part.

## Results

\`\`\`text
$(column -ts $'\t' "$RESULTS_FILE" 2>/dev/null || cat "$RESULTS_FILE")
\`\`\`

## Reputation statistics snapshots

\`\`\`text
$(for stats_file in "$RUN_DIR"/snapshots/*_db_stats.txt; do
    [[ -f "$stats_file" ]] || continue
    printf '%s: ' "$(basename "$stats_file" _db_stats.txt)"
    extract_reputation_stats "$stats_file"
  done)
\`\`\`
EOF
}

on_exit() {
  local rc=$?

  trap - EXIT
  if [[ -n "$RUN_DIR" && -n "$AUDIT_FILE" ]]; then
    finalize_audit "$rc" || true
  fi
  exit "$rc"
}

assert_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo 'Please run as root.' >&2
    exit 1
  fi
}

assert_no_load_running() {
  if ps -eo args | grep -F 'reputationdb load-dump' | grep -v grep >/dev/null; then
    echo 'Another reputationdb load-dump process is already running. Abort.' >&2
    ps -eo pid,etime,pcpu,pmem,args | grep -F 'reputationdb load-dump' | grep -v grep || true
    exit 1
  fi
}

assert_workdir() {
  if [[ ! -d "$WORKDIR" ]] || ! mountpoint -q "$WORKDIR"; then
    echo "$WORKDIR must already be mounted for the test. Do not create a new working directory during this validation run." >&2
    exit 1
  fi
}

collect_parts() {
  local date_value="$1"
  local path base part expected_part=1

  PACKAGE_FILES=()
  while IFS= read -r path; do
    PACKAGE_FILES+=("$path")
  done < <(find "$SRC_DIR" -maxdepth 1 -type f -name "reputation-day-${date_value}-part_part_*.zip" -print | sort -V)

  if [[ "${#PACKAGE_FILES[@]}" -eq 0 ]]; then
    echo "No day dump package found for $date_value in $SRC_DIR." >&2
    exit 1
  fi

  for path in "${PACKAGE_FILES[@]}"; do
    base="$(basename "$path")"
    if [[ ! "$base" =~ ^reputation-day-${date_value}-part_part_([0-9]+)\.zip$ ]]; then
      echo "Unexpected day dump filename: $base" >&2
      exit 1
    fi
    part="${BASH_REMATCH[1]}"
    if [[ "$part" -ne "$expected_part" ]]; then
      echo "Missing part $expected_part for day dump $date_value." >&2
      exit 1
    fi
    expected_part=$((expected_part + 1))
  done
}

record_manifest() {
  local date_value="$1"
  local path

  collect_parts "$date_value"
  for path in "${PACKAGE_FILES[@]}"; do
    printf '%s\t%s\t%s\t%s\n' \
      "$date_value" "$(basename "$path")" "$(stat -c '%s' "$path")" "$(sha256sum "$path" | awk '{print $1}')" >> "$RUN_DIR/manifest.tsv"
  done
}

capture_snapshot() {
  local label="$1"
  local date_value epoch snapshot_dir

  snapshot_dir="$RUN_DIR/snapshots"
  {
    date '+%F %T %Z'
    cd /
    reputationdb last-dump-metadata 2>&1 || true
  } > "$snapshot_dir/${label}_last_dump_metadata.txt"
  reputationdb db-stats > "$snapshot_dir/${label}_db_stats.txt" 2>&1 || true
  ps -eo pid,etime,pcpu,pmem,args > "$snapshot_dir/${label}_processes.txt"

  for date_value in "${TEST_DATES[@]}"; do
    epoch="$(date_to_epoch "$date_value")"
    reputationdb get-row --cf dumps --key "mt#$epoch" > "$snapshot_dir/${label}_${date_value}_dump_row.txt" 2>&1 || true
  done
}

assert_metadata_absent() {
  local date_value="$1"
  local epoch result_file

  epoch="$(date_to_epoch "$date_value")"
  result_file="$RUN_DIR/snapshots/preflight_${date_value}_dump_row.txt"
  reputationdb get-row --cf dumps --key "mt#$epoch" > "$result_file" 2>&1 || true
  if grep -q 'Key not found' "$result_file"; then
    record_result 'preflight' "$date_value" 'fresh-dump-metadata-row' 'PASS' "mt#$epoch is absent"
    return 0
  fi

  record_result 'preflight' "$date_value" 'fresh-dump-metadata-row' 'FAIL' "mt#$epoch already exists; test would not be fresh"
  echo "Dump metadata already exists for $date_value. Refusing a non-fresh test; see $result_file." >&2
  exit 1
}

verify_persisted_dump_metadata() {
  local phase="$1"
  local date_value="$2"
  local epoch row_file

  epoch="$(date_to_epoch "$date_value")"
  row_file="$RUN_DIR/snapshots/${phase}_${date_value}_dump_row.txt"
  reputationdb get-row --cf dumps --key "mt#$epoch" > "$row_file" 2>&1 || true

  if grep -q "\"to\":$epoch" "$row_file" \
    && grep -q '"dump_type":"day"' "$row_file" \
    && grep -q '"is_last_part":true' "$row_file"; then
    record_result "$phase" "$date_value" 'persisted-dump-metadata-row' 'PASS' "mt#$epoch exists with day metadata"
    return 0
  fi

  record_result "$phase" "$date_value" 'persisted-dump-metadata-row' 'FAIL' "mt#$epoch is missing or inconsistent"
  echo "RSDB did not expose the expected persisted dump metadata for $date_value; see $row_file." >&2
  return 1
}

run_stage() {
  local phase="$1"
  local date_value="$2"
  local path base part_log rc=0

  collect_parts "$date_value"
  for path in "${PACKAGE_FILES[@]}"; do
    base="$(basename "$path")"
    part_log="$RUN_DIR/imports/${phase}_${base}.log"
    log "START $phase: $base"
    set +e
    (
      cd "$WORKDIR"
      reputationdb load-dump --file-path "$path"
    ) > "$part_log" 2>&1
    rc=$?
    set -e

    if [[ "$rc" -ne 0 ]] || ! grep -q 'Load dump successfully' "$part_log"; then
      record_result "$phase" "$date_value" "load-dump $(basename "$path")" 'FAIL' "exit=$rc; see imports/$(basename "$part_log")"
      echo "Import stage $phase failed for $base; later stages will not run. See $part_log." >&2
      return 1
    fi
    record_result "$phase" "$date_value" "load-dump $(basename "$path")" 'PASS' 'exit=0 and success marker present'
  done

  capture_snapshot "$phase"
  verify_persisted_dump_metadata "$phase" "$date_value"
  log "DONE $phase: $date_value"
}

run_duplicate_stage() {
  local phase='04_duplicate_first'
  local date_value="$FIRST_DATE"
  local path base part_log rc=0

  collect_parts "$date_value"
  for path in "${PACKAGE_FILES[@]}"; do
    base="$(basename "$path")"
    part_log="$RUN_DIR/imports/${phase}_${base}.log"
    log "START $phase: $base"
    set +e
    (
      cd "$WORKDIR"
      reputationdb load-dump --file-path "$path"
    ) > "$part_log" 2>&1
    rc=$?
    set -e

    if grep -qi 'dump data was already loaded' "$part_log"; then
      record_result "$phase" "$date_value" "load-dump $(basename "$path")" 'REJECTED' "exit=$rc; duplicate protection marker present"
      continue
    fi

    if [[ "$rc" -eq 0 ]] && grep -q 'Load dump successfully' "$part_log"; then
      record_result "$phase" "$date_value" "load-dump $(basename "$path")" 'ACCEPTED' 'product accepted a second successful load'
      continue
    fi

    record_result "$phase" "$date_value" "load-dump $(basename "$path")" 'FAIL' "exit=$rc; no duplicate protection marker"
    echo "Duplicate import returned an unclassified failure for $base; see $part_log." >&2
    return 1
  done

  capture_snapshot "$phase"
  verify_persisted_dump_metadata "$phase" "$date_value"
  log "DONE $phase: duplicate import behavior recorded for $date_value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --first)
      FIRST_DATE="${2:-}"
      shift 2
      ;;
    --second)
      SECOND_DATE="${2:-}"
      shift 2
      ;;
    --backfill)
      BACKFILL_DATE="${2:-}"
      shift 2
      ;;
    --run)
      MODE='run'
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for value in "$FIRST_DATE" "$SECOND_DATE" "$BACKFILL_DATE"; do
  if ! validate_date "$value"; then
    echo 'All three dates must be valid YYYY-MM-DD values.' >&2
    usage >&2
    exit 2
  fi
done

if [[ ! "$FIRST_DATE" < "$BACKFILL_DATE" || ! "$BACKFILL_DATE" < "$SECOND_DATE" ]]; then
  echo 'Dates must be ordered: --first < --backfill < --second.' >&2
  exit 2
fi

TEST_DATES=("$FIRST_DATE" "$SECOND_DATE" "$BACKFILL_DATE")
assert_root
assert_no_load_running
assert_workdir

umask 077
RUN_DIR="$RUN_ROOT/out_of_order_daily_$(date '+%Y%m%d_%H%M%S')"
RESULTS_FILE="$RUN_DIR/results.tsv"
AUDIT_FILE="$RUN_DIR/audit.md"
mkdir -p "$RUN_DIR/snapshots" "$RUN_DIR/imports"
printf '%s\n' "$(date '+%F %T %Z')" > "$RUN_DIR/started_at.txt"
printf 'phase\tdate\tcheck\tstatus\tdetail\n' > "$RESULTS_FILE"
printf 'date\tfile\tbytes\tsha256\n' > "$RUN_DIR/manifest.tsv"
trap on_exit EXIT

for date_value in "${TEST_DATES[@]}"; do
  record_manifest "$date_value"
  assert_metadata_absent "$date_value"
done
capture_snapshot 'before'

if [[ "$MODE" == 'dry-run' ]]; then
  for date_value in "${TEST_DATES[@]}"; do
    record_result 'preflight' "$date_value" 'load-dump' 'NOT_RUN' 'dry-run only'
  done
  record_result '04_duplicate_first' "$FIRST_DATE" 'load-dump' 'NOT_RUN' 'dry-run only; duplicate stage planned'
  log "Preflight passed. No imports executed. Evidence bundle: $RUN_DIR"
  exit 0
fi

run_stage '01_first' "$FIRST_DATE"
run_stage '02_gap' "$SECOND_DATE"
run_stage '03_backfill' "$BACKFILL_DATE"
run_duplicate_stage

log "Test completed. Evidence bundle: $RUN_DIR"
