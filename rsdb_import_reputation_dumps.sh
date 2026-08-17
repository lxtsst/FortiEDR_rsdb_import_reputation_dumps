#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="/tmp"
WORKDIR="/tmp/rsdb_ramwork"
TMPFS_SIZE="12G"
STATE_DIR="/var/lib/reputationdb/import_state"
STATE_FILE="$STATE_DIR/imported_dumps.tsv"
LOCK_FILE="$STATE_DIR/import.lock"
RUN_LOG_DIR="/var/log/reputationdb/import_runner"
RETENTION_DAYS=15
ROCKSDB_PATH="/var/lib/reputationdb/rocksdb_data"
ONE_GIB=1073741824
MIN_ROOT_AVAIL_BYTES=$((10 * ONE_GIB))
MIN_DB_AVAIL_BYTES=$((20 * ONE_GIB))
MODE="run"
ONLY_TYPE="all"
COVERAGE_GAP_ACTION="prompt"
LATEST_META_RANK=""
LATEST_META_DATE=""
LATEST_META_FROM_DATE=""
LATEST_META_PART=""
LATEST_META_TYPE=""
COVERAGE_GAP_TYPE=""
COVERAGE_GAP_DATE=""
INITIAL_CURSOR_AVAILABLE=0

usage() {
  cat <<'USAGE'
Usage:
  /tmp/rsdb_import_reputation_dumps.sh [--dry-run] [--type all|full|week|day] [--on-coverage-gap abort|prompt|import-prefix]

Behavior:
  - Discovers reputation dump zip files in /tmp.
  - Imports full first, then interleaves week/day packages by date.
  - Skips files already recorded in state with the same name and size, or
    covered by current reputationdb metadata.
  - Detects missing incremental coverage before import. In an interactive run,
    prompts to import only the verified continuous prefix or to exit.
  - Uses /tmp/rsdb_ramwork tmpfs as the working directory for large full parts.
  - Records successful imports in /var/lib/reputationdb/import_state/imported_dumps.tsv.
  - New records use file name and size only to avoid hashing multi-GB dump files.
  - Deletes imported reputation dump files in /tmp when they are older than 15 days.
  - If RocksDB is rebuilt, cleared, or restored from backup, review or clear
    /var/lib/reputationdb/import_state/imported_dumps.tsv first. Otherwise old
    state can make the script skip files that are no longer present in RocksDB.

Examples:
  /tmp/rsdb_import_reputation_dumps.sh --dry-run
  /tmp/rsdb_import_reputation_dumps.sh
  /tmp/rsdb_import_reputation_dumps.sh --type week
  /tmp/rsdb_import_reputation_dumps.sh --on-coverage-gap import-prefix
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      MODE="dry-run"
      shift
      ;;
    --type)
      ONLY_TYPE="${2:-}"
      case "$ONLY_TYPE" in
        all|full|week|day) ;;
        *) echo "Invalid --type: $ONLY_TYPE" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --on-coverage-gap)
      COVERAGE_GAP_ACTION="${2:-}"
      case "$COVERAGE_GAP_ACTION" in
        abort|prompt|import-prefix) ;;
        *) echo "Invalid --on-coverage-gap: $COVERAGE_GAP_ACTION" >&2; exit 2 ;;
      esac
      shift 2
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

log() {
  printf "[%s] %s\n" "$(date '+%F %T %Z')" "$*"
}

rank_for_type() {
  case "$1" in
    full) echo 1 ;;
    week) echo 2 ;;
    day) echo 3 ;;
    *) echo 9 ;;
  esac
}

parse_dump_basename() {
  local base="$1"
  if [[ "$base" =~ ^reputation-(full|week|day)-([0-9]{4}-[0-9]{2}-[0-9]{2})-part_part_([0-9]+)\.zip$ ]]; then
    printf "%s|%s|%s\n" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return 0
  fi
  return 1
}

clear_latest_metadata_cursor() {
  LATEST_META_RANK=""
  LATEST_META_DATE=""
  LATEST_META_FROM_DATE=""
  LATEST_META_PART=""
  LATEST_META_TYPE=""
}

set_latest_metadata_cursor_from_output() {
  local out="$1"
  local type date part from_date

  clear_latest_metadata_cursor
  out="${out//$'\n'/ }"
  from_date=""
  if [[ "$out" =~ from:[[:space:]]*([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
    from_date="${BASH_REMATCH[1]}"
  fi
  if [[ ! "$out" =~ type:[[:space:]]*(full|week|day)[[:space:]]+from:.*to:([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]]+partNum:[[:space:]]*([0-9]+) ]]; then
    return 1
  fi

  type="${BASH_REMATCH[1]}"
  date="${BASH_REMATCH[2]}"
  part="${BASH_REMATCH[3]}"
  LATEST_META_TYPE="$type"
  LATEST_META_DATE="$date"
  LATEST_META_FROM_DATE="$from_date"
  LATEST_META_PART="$part"
  LATEST_META_RANK="$(rank_for_type "$type")"
  return 0
}

load_latest_metadata_cursor() {
  local out

  # last-dump-metadata can hit a RocksDB LOCK when invoked from /tmp or through
  # some pipelines on this RSDB build. Keep metadata reads out of the dump
  # working directory and avoid piping reputationdb directly.
  out="$(cd / && reputationdb last-dump-metadata 2>&1 || true)"
  if ! set_latest_metadata_cursor_from_output "$out"; then
    log "WARNING: reputationdb last-dump-metadata returned no parseable cursor; metadata-based coverage skips are disabled until a later refresh succeeds."
    return 1
  fi

  log "Latest DB metadata cursor: $LATEST_META_TYPE $LATEST_META_FROM_DATE to $LATEST_META_DATE part $LATEST_META_PART"
}

covered_by_latest_metadata() {
  local base="$1"
  local parsed type date part rank

  [[ -n "$LATEST_META_RANK" ]] || return 1
  parsed="$(parse_dump_basename "$base")" || return 1
  IFS='|' read -r type date part <<< "$parsed"
  rank="$(rank_for_type "$type")"

  if [[ "$LATEST_META_TYPE" == "week" && "$type" == "day" && -n "$LATEST_META_FROM_DATE" ]]; then
    if [[ ( "$date" == "$LATEST_META_FROM_DATE" || "$date" > "$LATEST_META_FROM_DATE" ) && ( "$date" == "$LATEST_META_DATE" || "$date" < "$LATEST_META_DATE" ) ]]; then
      return 0
    fi
  fi

  # A newer metadata date is not proof that every earlier package was loaded.
  # The explicit week range above is enough to cover its interior day dumps;
  # otherwise, only an equal-date type/part relationship is safe to skip.
  if [[ "$date" < "$LATEST_META_DATE" ]]; then
    return 1
  fi
  if [[ "$date" > "$LATEST_META_DATE" ]]; then
    return 1
  fi

  if (( rank < LATEST_META_RANK )); then
    return 0
  fi
  if (( rank > LATEST_META_RANK )); then
    return 1
  fi
  (( part <= LATEST_META_PART ))
}

state_has_basename() {
  local base="$1"
  [[ -f "$STATE_FILE" ]] || return 1
  awk -F '\t' -v b="$base" '$2 == b { found=1 } END { exit found ? 0 : 1 }' "$STATE_FILE"
}

file_size() {
  local size

  if size="$(stat -c '%s' "$1" 2>/dev/null)"; then
    printf '%s\n' "$size"
  else
    stat -f '%z' "$1"
  fi
}

state_has_file() {
  local path="$1"
  local base size
  base="$(basename "$path")"
  [[ -f "$STATE_FILE" ]] || return 1
  size="$(file_size "$path")"

  awk -F '\t' -v b="$base" -v s="$size" '
    $2 == b {
      if ($3 == s) size_match=1
      else size_mismatch=1
    }
    END {
      if (size_match) exit 0
      if (size_mismatch) exit 2
      exit 1
    }
  ' "$STATE_FILE"
}

part_log_already_loaded() {
  local part_log="$1"
  grep -qi "dump data was already loaded" "$part_log"
}

part_log_missing_update() {
  local part_log="$1"
  grep -qi "db is missing update to use this dump" "$part_log"
}

report_missing_update() {
  local base="$1"
  local part_log="$2"
  local parsed type date _part

  log "FAILED incremental coverage: $base requires a closer update than the current DB metadata cursor."
  log "Relevant reputationdb error:"
  grep -iE "Failed to validate metadata|latestUpdateDate" "$part_log" | tail -n 5 | sed 's/^/  /' || true
  log "Full command output log: $part_log"

  parsed="$(parse_dump_basename "$base")" || return 0
  IFS='|' read -r type date _part <<< "$parsed"
  if [[ -n "$LATEST_META_DATE" ]]; then
    print_recovery_advice "$LATEST_META_DATE" "$date"
  fi
}

is_imported_path() {
  local path="$1"
  local base

  base="$(basename "$path")"
  if state_has_file "$path"; then
    return 0
  fi

  covered_by_latest_metadata "$base"
}

is_imported_basename() {
  local base="$1"
  state_has_basename "$base" || covered_by_latest_metadata "$base"
}

record_state() {
  local path="$1"
  local state_source="$2"
  local base size rc
  base="$(basename "$path")"
  size="$(file_size "$path")"

  set +e
  state_has_file "$path"
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    log "Recording $state_source dump state by file name and size: $base"
    printf "%s\t%s\t%s\t%s\t%s\n" "$(date '+%F %T %Z')" "$base" "$size" "$state_source" "$path" >> "$STATE_FILE"
  fi
}

record_imported() {
  record_state "$1" "name_size_only"
}

record_covered_by_metadata() {
  record_state "$1" "metadata_coverage"
}

expected_basename() {
  local type="$1"
  local date="$2"
  local part="$3"
  printf "reputation-%s-%s-part_part_%s.zip" "$type" "$date" "$part"
}

bytes_available() {
  df --output=avail -B1 "$1" | awk 'NR == 2 { print $1 }'
}

human_bytes() {
  numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"
}

cleanup_workdir_temp() {
  if [[ -d "$WORKDIR" ]] && mountpoint -q "$WORKDIR"; then
    if ps -eo args | grep -F "reputationdb load-dump" | grep -v grep >/dev/null; then
      log "Skip temporary cleanup because a reputationdb load-dump process is still running."
      return 0
    fi
    find "$WORKDIR" -mindepth 1 -maxdepth 1 -type f -name "data_reputation-*.zip*" -delete 2>/dev/null || true
  fi
}

cleanup_old_imported_dumps() {
  local path base

  log "Checking for imported dump files older than $RETENTION_DAYS days in $SRC_DIR"
  find "$SRC_DIR" -maxdepth 1 -type f -name 'reputation-*-part_part_*.zip' -mtime +"$RETENTION_DAYS" | while IFS= read -r path; do
    base="$(basename "$path")"
    if [[ ! "$base" =~ ^reputation-(full|week|day)-[0-9]{4}-[0-9]{2}-[0-9]{2}-part_part_[0-9]+\.zip$ ]]; then
      continue
    fi

    if is_imported_path "$path"; then
      if [[ "$MODE" == "dry-run" ]]; then
        log "DRY-RUN would delete old imported dump: $path"
      else
        log "DELETE old imported dump: $path"
        rm -f -- "$path"
      fi
    else
      log "KEEP old dump not confirmed imported: $path"
    fi
  done
}

ensure_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Please run as root." >&2
    exit 1
  fi
}

ensure_workdir() {
  mkdir -p "$WORKDIR"
  if ! mountpoint -q "$WORKDIR"; then
    log "$WORKDIR is not mounted; mounting tmpfs size=$TMPFS_SIZE"
    mount -t tmpfs -o "size=$TMPFS_SIZE" tmpfs "$WORKDIR"
  fi

  if [[ "$(findmnt -n -o FSTYPE --target "$WORKDIR")" != "tmpfs" ]]; then
    echo "$WORKDIR is mounted, but not as tmpfs. Abort." >&2
    findmnt --target "$WORKDIR" >&2 || true
    exit 1
  fi
}

assert_no_load_running() {
  if ps -eo args | grep -F "reputationdb load-dump" | grep -v grep >/dev/null; then
    echo "Another reputationdb load-dump process is already running. Abort." >&2
    ps -eo pid,etime,pcpu,pmem,args | grep -F "reputationdb load-dump" | grep -v grep || true
    exit 1
  fi
}

warn_reputationdb_server_running() {
  if ps -eo pid,args | grep -F "reputationDBServer --server" | grep -v grep >/dev/null; then
    log "Notice: reputationDBServer --server is running. This is a resident service and imports usually can continue; if a RocksDB LOCK error occurs, consider stopping the service before retrying."
    ps -eo pid,etime,pcpu,pmem,args | grep -F "reputationDBServer --server" | grep -v grep || true
  fi
}

check_filesystem_space() {
  local root_avail db_target db_avail

  root_avail="$(bytes_available /)"
  if (( root_avail < MIN_ROOT_AVAIL_BYTES )); then
    echo "Root filesystem free space is too low: $(human_bytes "$root_avail"), required at least $(human_bytes "$MIN_ROOT_AVAIL_BYTES")." >&2
    df -h /
    exit 1
  fi

  db_target="$ROCKSDB_PATH"
  [[ -e "$db_target" ]] || db_target="$(dirname "$ROCKSDB_PATH")"
  db_avail="$(bytes_available "$db_target")"
  if (( db_avail < MIN_DB_AVAIL_BYTES )); then
    echo "RocksDB filesystem free space is too low: $(human_bytes "$db_avail"), required at least $(human_bytes "$MIN_DB_AVAIL_BYTES")." >&2
    df -h "$db_target"
    exit 1
  fi

  log "Filesystem space:"
  df -h "$WORKDIR" "$db_target" /
}

check_workdir_space_for_dump() {
  local path="$1"
  local dump_size required available
  dump_size="$(file_size "$path")"
  required=$((dump_size + ONE_GIB))
  available="$(bytes_available "$WORKDIR")"

  if (( available < required )); then
    echo "Not enough tmpfs space for $(basename "$path"). Available: $(human_bytes "$available"), required: $(human_bytes "$required") (dump size + 1GiB)." >&2
    df -h "$WORKDIR"
    exit 1
  fi
}

discover_files() {
  local path base type date part rank group
  find "$SRC_DIR" -maxdepth 1 -type f -name 'reputation-*-part_part_*.zip' | while IFS= read -r path; do
    base="$(basename "$path")"
    if [[ "$base" =~ ^reputation-(full|week|day)-([0-9]{4}-[0-9]{2}-[0-9]{2})-part_part_([0-9]+)\.zip$ ]]; then
      type="${BASH_REMATCH[1]}"
      date="${BASH_REMATCH[2]}"
      part="${BASH_REMATCH[3]}"
      if [[ "$ONLY_TYPE" != "all" && "$ONLY_TYPE" != "$type" ]]; then
        continue
      fi
      rank="$(rank_for_type "$type")"
      if [[ "$type" == "full" ]]; then
        group=1
      else
        group=2
      fi
      printf "%s|%s|%s|%010d|%s|%s|%s\n" "$group" "$rank" "$date" "$part" "$type" "$part" "$path"
    fi
  done | sort -t '|' -k1,1n -k3,3 -k2,2n -k4,4n | cut -d '|' -f2-
}

report_nonconforming_reputation_archives() {
  local path base found=0

  while IFS= read -r path; do
    base="$(basename "$path")"
    if parse_dump_basename "$base" >/dev/null; then
      continue
    fi

    if (( found == 0 )); then
      log "WARNING: Found ZIP archive file(s) that do not match the required reputation-dump filename format and will not be imported:"
    fi
    printf '  %s\n' "$path"
    found=1
  done < <(find "$SRC_DIR" -maxdepth 1 -type f -name '*.zip' -print | sort)

  if (( found )); then
    log "Restore the original FortiEDR filename before running the importer."
    return 1
  fi
  return 0
}

state_has_records() {
  [[ -f "$STATE_FILE" ]] || return 1
  awk 'NF { found=1 } END { exit found ? 0 : 1 }' "$STATE_FILE"
}

validate_bootstrap_preconditions() {
  local plan_file="$1"
  local _rank date _part_padded type _part _path full_count=0
  local -a full_dates=()
  declare -A seen_full_dates=()

  (( INITIAL_CURSOR_AVAILABLE == 0 )) || return 0

  # A state row without current DB metadata cannot prove that the database is
  # still populated. Do not let it make a fresh or unreadable RSDB look ready.
  if state_has_records; then
    echo "RSDB metadata has no parseable cursor while $STATE_FILE contains import-state records. Abort: do not trust state records as a bootstrap baseline. Verify the database, then clear or retain the state file deliberately before retrying." >&2
    return 1
  fi

  while IFS='|' read -r _rank date _part_padded type _part _path; do
    [[ "$type" == "full" ]] || continue
    if [[ -n "${seen_full_dates[$date]:-}" ]]; then
      continue
    fi
    seen_full_dates["$date"]=1
    full_dates+=("$date")
    full_count=$((full_count + 1))
  done < "$plan_file"

  if (( full_count == 0 )); then
    echo "RSDB has no parseable metadata cursor and no full dump is available in $SRC_DIR. A new or empty RSDB must start from one complete full dump; weekly and daily dumps are incremental only. Abort without calling reputationdb." >&2
    return 1
  fi

  if (( full_count > 1 )); then
    echo "RSDB has no parseable metadata cursor and multiple full dump dates are present. Abort without choosing one automatically; keep exactly one complete full dump date in $SRC_DIR for bootstrap:" >&2
    printf '  reputation-full-%s-part_part_*.zip\n' "${full_dates[@]}" >&2
    return 1
  fi

  log "Bootstrap mode: no current DB cursor is available; using complete full dump date ${full_dates[0]} as the required initial baseline."
}

has_new_week_on_date() {
  local plan_file="$1"
  local target_date="$2"
  local _rank date _part_padded type _part path

  while IFS='|' read -r _rank date _part_padded type _part path; do
    if [[ "$type" == "week" && "$date" == "$target_date" ]] && ! is_imported_path "$path"; then
      return 0
    fi
  done < "$plan_file"
  return 1
}

validate_contiguous_parts() {
  local plan_file="$1"
  local date type part key i base
  declare -A seen=()
  declare -A max_part=()
  declare -A key_type=()
  declare -A key_date=()

  while IFS='|' read -r _rank date _part_padded type part _path; do
    key="$type|$date"
    seen["$key|$part"]=1
    key_type["$key"]="$type"
    key_date["$key"]="$date"
    if [[ -z "${max_part[$key]:-}" || "$part" -gt "${max_part[$key]}" ]]; then
      max_part["$key"]="$part"
    fi
  done < "$plan_file"

  for key in "${!max_part[@]}"; do
    type="${key_type[$key]}"
    date="${key_date[$key]}"
    for ((i=1; i<=max_part[$key]; i++)); do
      if [[ -n "${seen[$key|$i]:-}" ]]; then
        continue
      fi

      base="$(expected_basename "$type" "$date" "$i")"
      if is_imported_basename "$base"; then
        continue
      fi

      echo "Missing part $i for $type|$date, and it is not confirmed imported: $base" >&2
      return 1
    done
  done
}

date_to_epoch() {
  local date_value="$1"

  if date -u -d "$date_value" '+%s' >/dev/null 2>&1; then
    date -u -d "$date_value" '+%s'
  else
    date -u -j -f '%Y-%m-%d' "$date_value" '+%s'
  fi
}

date_add_days() {
  local date_value="$1"
  local days="$2"
  local bsd_modifier

  if date -u -d "$date_value $days days" '+%F' >/dev/null 2>&1; then
    date -u -d "$date_value $days days" '+%F'
  else
    if [[ "$days" == -* ]]; then
      bsd_modifier="$days"
    else
      bsd_modifier="+$days"
    fi
    date -u -j -v"${bsd_modifier}"d -f '%Y-%m-%d' "$date_value" '+%F'
  fi
}

days_between() {
  local start_date="$1"
  local end_date="$2"
  local start_epoch end_epoch

  start_epoch="$(date_to_epoch "$start_date")"
  end_epoch="$(date_to_epoch "$end_date")"
  printf '%s\n' "$(((end_epoch - start_epoch) / 86400))"
}

print_no_package_download_guidance() {
  local today cursor checkpoint delta tail_start

  log "No matching reputation dump files found in $SRC_DIR."
  report_nonconforming_reputation_archives || true

  if (( INITIAL_CURSOR_AVAILABLE == 0 )) || [[ -z "$LATEST_META_DATE" ]]; then
    log "Cannot create a safe incremental download plan because RSDB has no parseable metadata cursor."
    if state_has_records; then
      log "Import-state records exist, but they are not a substitute for current DB metadata. Resolve the metadata read first."
    else
      log "For a new or empty RSDB, download exactly one complete current full dump bundle first. After placing it in $SRC_DIR, run --dry-run; the importer will validate the later week/day chain from that full dump date."
    fi
    return 0
  fi

  # Dump metadata dates represent UTC day boundaries on this RSDB build; keep
  # the recommendation date arithmetic in the same time basis.
  today="$(date -u '+%F')"
  if [[ "$LATEST_META_DATE" > "$today" || "$LATEST_META_DATE" == "$today" ]]; then
    log "DB metadata already ends at $LATEST_META_DATE; this is current relative to the current UTC date $today. No update package is recommended."
    return 0
  fi

  delta="$(days_between "$LATEST_META_DATE" "$today")"
  log "DB metadata ends at $LATEST_META_DATE; current UTC date is $today (${delta} day(s) later)."
  log "Recommended low-overlap download plan (based on package dates, not a live package-portal inventory):"
  log "  Prefer one week package for each complete seven-day interval, then daily packages only for the remaining tail."

  cursor="$LATEST_META_DATE"
  while (( $(days_between "$cursor" "$today") >= 7 )); do
    checkpoint="$(date_add_days "$cursor" 7)"
    printf '  week: reputation-week-%s-part_part_*.zip\n' "$checkpoint"
    printf '    fallback if unavailable: reputation-day-%s through reputation-day-%s\n' \
      "$(date_add_days "$cursor" 1)" "$checkpoint"
    cursor="$checkpoint"
  done

  if [[ "$cursor" < "$today" ]]; then
    tail_start="$(date_add_days "$cursor" 1)"
    log "  Daily tail (no intentional weekly overlap):"
    while [[ "$tail_start" < "$today" || "$tail_start" == "$today" ]]; do
      printf '  day:  reputation-day-%s-part_part_*.zip\n' "$tail_start"
      tail_start="$(date_add_days "$tail_start" 1)"
    done
  fi

  log "Use packages with the listed dates. If a recommended week package is not published, use its printed daily fallback range rather than skipping the interval. Re-run --dry-run after copying packages to $SRC_DIR."
}

missing_day_dates() {
  local previous_date="$1"
  local next_date="$2"
  local current_date separator=""

  current_date="$(date_add_days "$previous_date" 1)"
  while [[ "$current_date" < "$next_date" ]]; do
    printf '%s%s' "$separator" "$current_date"
    separator=", "
    current_date="$(date_add_days "$current_date" 1)"
  done
}

print_missing_daily_packages() {
  local previous_date="$1"
  local next_date="$2"
  local current_date total_days

  total_days="$(days_between "$previous_date" "$next_date")"
  (( total_days > 1 )) || return 0

  if (( total_days > 31 )); then
    log "Daily alternative: ${total_days} daily dates are missing, from $(date_add_days "$previous_date" 1) through $(date_add_days "$next_date" -1). Prefer the weekly recovery checkpoints below."
    return 0
  fi

  log "Daily-package alternative (download every listed date before retrying $next_date):"
  current_date="$(date_add_days "$previous_date" 1)"
  while [[ "$current_date" < "$next_date" ]]; do
    printf '  reputation-day-%s-part_part_*.zip\n' "$current_date"
    current_date="$(date_add_days "$current_date" 1)"
  done
}

print_weekly_recovery_packages() {
  local previous_date="$1"
  local next_date="$2"
  local checkpoint

  checkpoint="$(date_add_days "$previous_date" 7)"
  [[ "$checkpoint" < "$next_date" ]] || return 0

  log "Weekly-package recovery checkpoints (use the nearest available weekly package on or before each date):"
  while [[ "$checkpoint" < "$next_date" ]]; do
    printf '  reputation-week-%s-part_part_*.zip\n' "$checkpoint"
    checkpoint="$(date_add_days "$checkpoint" 7)"
  done
}

print_recovery_advice() {
  local previous_date="$1"
  local next_date="$2"
  local delta

  delta="$(days_between "$previous_date" "$next_date")"
  if (( delta <= 1 )); then
    log "No earlier date can be derived from the DB cursor; review the full command output log before retrying."
    return 0
  fi

  log "Recovery required before retrying $next_date: current DB cursor ends at $previous_date and the target is $delta days later."
  print_weekly_recovery_packages "$previous_date" "$next_date"
  print_missing_daily_packages "$previous_date" "$next_date"
}

validate_incremental_coverage() {
  local plan_file="$1"
  local date type path delta coverage_cursor="" missing_dates
  local has_gap=0 has_unsafe=0

  COVERAGE_GAP_TYPE=""
  COVERAGE_GAP_DATE=""
  coverage_cursor="$LATEST_META_DATE"

  while IFS='|' read -r _rank date _part_padded type _part path; do
    if is_imported_path "$path"; then
      continue
    fi

    if [[ -n "$coverage_cursor" && "$date" < "$coverage_cursor" ]]; then
      echo "Unsafe late/backfill package: $(basename "$path") is older than the preceding coverage cursor $coverage_cursor and has no matching import-state record. Abort without calling reputationdb." >&2
      has_unsafe=1
      continue
    fi

    case "$type" in
      full)
        coverage_cursor="$date"
        ;;
      week)
        if [[ -n "$coverage_cursor" ]]; then
          delta="$(days_between "$coverage_cursor" "$date")"
          if (( delta < 0 )); then
            echo "Unsafe late weekly package: $date is before the preceding coverage cursor $coverage_cursor. Abort without calling reputationdb." >&2
            has_unsafe=1
            continue
          elif (( delta > 7 )); then
            echo "Missing incremental coverage before weekly package $date: preceding cursor is $coverage_cursor and the next weekly package is $delta days later. Abort without calling reputationdb." >&2
            print_recovery_advice "$coverage_cursor" "$date" >&2
            COVERAGE_GAP_TYPE="week"
            COVERAGE_GAP_DATE="$date"
            has_gap=1
            break
          fi
        fi
        coverage_cursor="$date"
        ;;
      day)
        if [[ -n "$coverage_cursor" ]]; then
          delta="$(days_between "$coverage_cursor" "$date")"
          if (( delta < 0 )); then
            echo "Unsafe late daily package: $date is before the preceding coverage cursor $coverage_cursor. Abort without calling reputationdb." >&2
            has_unsafe=1
            continue
          elif (( delta > 1 )); then
            missing_dates="$(missing_day_dates "$coverage_cursor" "$date")"
            echo "Missing daily package date(s): $missing_dates (between $coverage_cursor and $date). Abort without calling reputationdb." >&2
            print_missing_daily_packages "$coverage_cursor" "$date" >&2
            COVERAGE_GAP_TYPE="day"
            COVERAGE_GAP_DATE="$date"
            has_gap=1
            break
          fi
        fi
        coverage_cursor="$date"
        ;;
    esac
  done < "$plan_file"

  if (( has_unsafe )); then
    return 2
  fi
  if (( has_gap )); then
    return 1
  fi
  return 0
}

build_safe_prefix_plan() {
  local plan_file="$1"
  local prefix_plan_file="$2"
  local rank date stop_at_gap=0

  : > "$prefix_plan_file"
  while IFS='|' read -r rank date _part_padded _type _part _path; do
    if [[ "$_type" == "$COVERAGE_GAP_TYPE" && "$date" == "$COVERAGE_GAP_DATE" ]]; then
      stop_at_gap=1
    fi
    if (( ! stop_at_gap )) && ! is_imported_path "$_path"; then
      printf '%s|%s|%s|%s|%s|%s\n' "$rank" "$date" "$_part_padded" "$_type" "$_part" "$_path" >> "$prefix_plan_file"
    fi
  done < "$plan_file"
}

resolve_incremental_coverage() {
  local plan_file="$1"
  local prefix_plan_file="$2"
  local rc response prefix_count

  SELECTED_PLAN_FILE="$plan_file"
  set +e
  validate_incremental_coverage "$plan_file"
  rc=$?
  set -e

  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi

  if [[ "$rc" -eq 2 ]]; then
    echo "Unsafe late/backfill package detected. No packages will be imported; recover a continuous chain from the current DB cursor instead." >&2
    return 1
  fi

  build_safe_prefix_plan "$plan_file" "$prefix_plan_file"
  prefix_count="$(wc -l < "$prefix_plan_file" | tr -d ' ')"
  if [[ "$prefix_count" -eq 0 ]]; then
    echo "No verified continuous package exists before the first coverage gap. No packages will be imported." >&2
    return 1
  fi

  echo "Safe prefix available: $prefix_count package part(s) before ${COVERAGE_GAP_TYPE} ${COVERAGE_GAP_DATE}. Packages at and after that boundary will remain in $SRC_DIR for a later run." >&2
  case "$COVERAGE_GAP_ACTION" in
    abort)
      echo "No packages will be imported. Download the suggested package(s) and run again." >&2
      return 1
      ;;
    import-prefix)
      log "Proceeding with the verified continuous prefix only; later packages remain pending."
      SELECTED_PLAN_FILE="$prefix_plan_file"
      return 0
      ;;
    prompt)
      if [[ "$MODE" == "dry-run" || ! -t 0 ]]; then
        echo "No packages will be imported. The prompt policy cannot select a prefix in dry-run or non-interactive mode; use --on-coverage-gap import-prefix to preview or run only the verified prefix." >&2
        return 1
      fi
      read -r -p "Missing coverage detected. Import only the verified prefix before ${COVERAGE_GAP_TYPE} ${COVERAGE_GAP_DATE}? [p/E] " response
      case "$response" in
        p|P|prefix|PREFIX)
          log "Proceeding with the verified continuous prefix only; later packages remain pending."
          SELECTED_PLAN_FILE="$prefix_plan_file"
          return 0
          ;;
        *)
          echo "No packages will be imported. Download the suggested package(s) and run again." >&2
          return 1
          ;;
      esac
      ;;
  esac
}

import_one() {
  local type="$1"
  local date="$2"
  local part="$3"
  local path="$4"
  local base part_log rc

  base="$(basename "$path")"
  part_log="$RUN_LOG_DIR/${type}_${date}_part_${part}_$(date '+%Y%m%d_%H%M%S').log"

  set +e
  state_has_file "$path"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    log "SKIP already imported from state: $base"
    return 0
  elif [[ "$rc" -eq 2 ]]; then
    log "State has $base but file size changed; continuing with import attempt."
  fi

  if covered_by_latest_metadata "$base"; then
    log "SKIP already covered by latest DB metadata: $base"
    record_covered_by_metadata "$path"
    return 0
  fi

  assert_no_load_running
  log "Cleaning old temporary data_reputation files from $WORKDIR"
  cleanup_workdir_temp
  check_filesystem_space
  check_workdir_space_for_dump "$path"
  df -h "$WORKDIR"

  log "START import: $base"
  log "Command output log: $part_log"

  set +e
  (
    cd "$WORKDIR"
    reputationdb load-dump --file-path "$path"
  ) > "$part_log" 2>&1
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    if part_log_already_loaded "$part_log"; then
      log "SKIP already loaded according to reputationdb metadata validation: $base"
      record_imported "$path"
      cleanup_workdir_temp
      return 0
    fi
    if part_log_missing_update "$part_log"; then
      report_missing_update "$base" "$part_log"
      tail -n 80 "$part_log" || true
      cleanup_workdir_temp
      exit 4
    fi
    log "FAILED import: $base exit=$rc"
    if grep -qiE "Signature verification failed|verification timed out" "$part_log"; then
      log "Signature verification failed or timed out for $base. Temporary files will be cleaned; retry may succeed."
    fi
    tail -n 80 "$part_log" || true
    cleanup_workdir_temp
    exit "$rc"
  fi

  if ! grep -q "Load dump successfully" "$part_log"; then
    if part_log_already_loaded "$part_log"; then
      log "SKIP already loaded according to reputationdb metadata validation: $base"
      record_imported "$path"
      cleanup_workdir_temp
      return 0
    fi
    if part_log_missing_update "$part_log"; then
      report_missing_update "$base" "$part_log"
      tail -n 80 "$part_log" || true
      cleanup_workdir_temp
      exit 4
    fi
    log "FAILED verification: command exited 0 but success marker was not found for $base"
    if grep -qiE "Signature verification failed|verification timed out" "$part_log"; then
      log "Signature verification failed or timed out for $base. Temporary files will be cleaned; retry may succeed."
    fi
    tail -n 80 "$part_log" || true
    cleanup_workdir_temp
    exit 3
  fi

  record_imported "$path"
  if load_latest_metadata_cursor; then
    log "Refreshed DB metadata after import; remaining packages will be checked against the actual coverage range."
  else
    log "WARNING: imported $base, but the DB metadata cursor could not be refreshed. Remaining packages will not be skipped based on coverage until the next successful refresh."
  fi
  log "DONE import: $base"
}

main() {
  ensure_root
  mkdir -p "$STATE_DIR" "$RUN_LOG_DIR"
  touch "$STATE_FILE"

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "Another import runner is already active. Abort." >&2
    exit 1
  fi

  assert_no_load_running
  warn_reputationdb_server_running
  if load_latest_metadata_cursor; then
    INITIAL_CURSOR_AVAILABLE=1
  else
    INITIAL_CURSOR_AVAILABLE=0
    log "No initial DB metadata cursor is available. An existing RSDB must restore metadata access; a new RSDB must provide exactly one complete full dump bundle."
  fi
  ensure_workdir
  check_filesystem_space
  trap cleanup_workdir_temp EXIT

  local plan_file prefix_plan_file original_plan_file
  plan_file="$(mktemp /tmp/rsdb_import_plan.XXXXXX)"
  prefix_plan_file="$(mktemp /tmp/rsdb_import_prefix.XXXXXX)"
  discover_files > "$plan_file"

  if [[ ! -s "$plan_file" ]]; then
    print_no_package_download_guidance
    rm -f "$plan_file"
    rm -f "$prefix_plan_file"
    exit 0
  fi

  validate_contiguous_parts "$plan_file"
  if ! validate_bootstrap_preconditions "$plan_file"; then
    log "Bootstrap preflight stopped the run. No dump was imported and no old dump file was deleted."
    rm -f "$plan_file"
    rm -f "$prefix_plan_file"
    exit 1
  fi
  if ! resolve_incremental_coverage "$plan_file" "$prefix_plan_file"; then
    log "Incremental coverage preflight stopped the run. No dump was imported and no old dump file was deleted."
    rm -f "$plan_file"
    rm -f "$prefix_plan_file"
    exit 1
  fi
  original_plan_file="$plan_file"
  plan_file="$SELECTED_PLAN_FILE"
  if [[ "$plan_file" != "$original_plan_file" ]]; then
    rm -f "$original_plan_file"
  fi

  log "Planned order:"
  while IFS='|' read -r _rank date _part_padded type part path; do
    if is_imported_path "$path"; then
      printf "  SKIP   %-4s %s part %s %s\n" "$type" "$date" "$part" "$path"
    elif [[ "$type" == "day" ]] && has_new_week_on_date "$plan_file" "$date"; then
      printf "  CHECK  %-4s %s part %s %s (decision deferred until the preceding week import refreshes DB metadata)\n" "$type" "$date" "$part" "$path"
    else
      printf "  IMPORT %-4s %s part %s %s\n" "$type" "$date" "$part" "$path"
    fi
  done < "$plan_file"

  if [[ "$MODE" == "dry-run" ]]; then
    cleanup_old_imported_dumps
    log "Dry run only; no imports executed."
    rm -f "$plan_file"
    rm -f "$prefix_plan_file"
    exit 0
  fi

  while IFS='|' read -r _rank date _part_padded type part path; do
    import_one "$type" "$date" "$part" "$path"
  done < "$plan_file"

  log "All eligible reputation dumps are imported or skipped."
  cleanup_old_imported_dumps
  log "Cleaning final temporary data_reputation files from $WORKDIR"
  cleanup_workdir_temp
  df -h "$WORKDIR"
  rm -f "$plan_file"
  rm -f "$prefix_plan_file"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
