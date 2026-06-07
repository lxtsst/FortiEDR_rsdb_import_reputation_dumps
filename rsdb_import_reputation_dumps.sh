#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="/tmp"
WORKDIR="/tmp/rsdb_ramwork"
TMPFS_SIZE="12G"
STATE_DIR="/var/lib/reputationdb/import_state"
STATE_FILE="$STATE_DIR/imported_dumps.tsv"
LOCK_FILE="$STATE_DIR/import.lock"
RUN_LOG_DIR="/var/log/reputationdb/import_runner"
CLI_LOG="/var/log/reputationdb/cli/reputationdb.log"
RETENTION_DAYS=15
ROCKSDB_PATH="/var/lib/reputationdb/rocksdb_data"
ONE_GIB=1073741824
MIN_ROOT_AVAIL_BYTES=$((10 * ONE_GIB))
MIN_DB_AVAIL_BYTES=$((20 * ONE_GIB))
MODE="run"
ONLY_TYPE="all"
LATEST_META_RANK=""
LATEST_META_DATE=""
LATEST_META_FROM_DATE=""
LATEST_META_PART=""
LATEST_META_TYPE=""

usage() {
  cat <<'USAGE'
Usage:
  /tmp/rsdb_import_reputation_dumps.sh [--dry-run] [--type all|full|week|day]

Behavior:
  - Discovers reputation dump zip files in /tmp.
  - Imports in order: full, then week, then day.
  - Skips files already recorded in state or already completed in reputationdb CLI logs.
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

load_latest_metadata_cursor() {
  local out type date part from_date

  # last-dump-metadata can hit a RocksDB LOCK when invoked from /tmp or through
  # some pipelines on this RSDB build. Keep metadata reads out of the dump
  # working directory and avoid piping reputationdb directly.
  out="$(cd / && reputationdb last-dump-metadata 2>&1 || true)"
  out="${out//$'\n'/ }"
  from_date=""
  if [[ "$out" =~ from:[[:space:]]*([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
    from_date="${BASH_REMATCH[1]}"
  fi
  if [[ "$out" =~ type:[[:space:]]*(full|week|day)[[:space:]]+from:.*to:([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]]+partNum:[[:space:]]*([0-9]+) ]]; then
    type="${BASH_REMATCH[1]}"
    date="${BASH_REMATCH[2]}"
    part="${BASH_REMATCH[3]}"
    LATEST_META_TYPE="$type"
    LATEST_META_DATE="$date"
    LATEST_META_FROM_DATE="$from_date"
    LATEST_META_PART="$part"
    LATEST_META_RANK="$(rank_for_type "$type")"
    if [[ -n "$from_date" ]]; then
      log "Latest DB metadata cursor: $type $from_date to $date part $part"
    else
      log "Latest DB metadata cursor: $type $date part $part"
    fi
  fi
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

  if (( rank < LATEST_META_RANK )); then
    return 0
  fi
  if (( rank > LATEST_META_RANK )); then
    return 1
  fi
  if [[ "$date" < "$LATEST_META_DATE" ]]; then
    return 0
  fi
  if [[ "$date" > "$LATEST_META_DATE" ]]; then
    return 1
  fi
  (( part <= LATEST_META_PART ))
}

state_has_basename() {
  local base="$1"
  [[ -f "$STATE_FILE" ]] || return 1
  awk -F '\t' -v b="$base" '$2 == b { found=1 } END { exit found ? 0 : 1 }' "$STATE_FILE"
}

state_has_file() {
  local path="$1"
  local base size
  base="$(basename "$path")"
  [[ -f "$STATE_FILE" ]] || return 1
  size="$(stat -c '%s' "$path")"

  awk -F '\t' -v b="$base" -v s="$size" '
    $2 == b {
      found=1
      if ($3 != s) size_mismatch=1
    }
    END {
      if (found && size_mismatch) exit 2
      exit found ? 0 : 1
    }
  ' "$STATE_FILE"
}

completed_in_cli_log() {
  local base="$1"
  local log_file parsed type date part

  parsed="$(parse_dump_basename "$base")" || return 1
  IFS='|' read -r type date part <<< "$parsed"

  # Successful imports write metadata near the end of the operation. Matching
  # metadata is more reliable than matching the initial "Validating..." line,
  # because multi-hour full imports can rotate CLI logs between start and finish.
  # FortiEDR rotates CLI logs as reputationdb-<timestamp>.log.gz, not only
  # reputationdb.log.*. Scan both forms so old successful full parts are found.
  for log_file in "$CLI_LOG" /var/log/reputationdb/cli/reputationdb*.log*; do
    [[ -e "$log_file" ]] || continue
    if [[ "$log_file" == *.gz ]]; then
      zcat -- "$log_file" 2>/dev/null
    else
      cat -- "$log_file" 2>/dev/null
    fi | awk -v type="$type" -v date="$date" -v part="$part" '
      index($0, "Saving metadata Dump metadata.") &&
      index($0, "type: " type) &&
      index($0, "to:" date) &&
      index($0, "partNum: " part " ") {
        found=1
      }
      END { exit found ? 0 : 1 }
    ' && return 0
  done

  return 1
}

part_log_already_loaded() {
  local part_log="$1"
  grep -qi "dump data was already loaded" "$part_log"
}

is_imported() {
  local base="$1"
  state_has_basename "$base" || covered_by_latest_metadata "$base" || completed_in_cli_log "$base"
}

record_imported() {
  local path="$1"
  local base size rc
  base="$(basename "$path")"
  size="$(stat -c '%s' "$path")"

  set +e
  state_has_file "$path"
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    log "Recording imported dump state by file name and size: $base"
    printf "%s\t%s\t%s\t%s\t%s\n" "$(date '+%F %T %Z')" "$base" "$size" "name_size_only" "$path" >> "$STATE_FILE"
  fi
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

    if is_imported "$base"; then
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
  dump_size="$(stat -c '%s' "$path")"
  required=$((dump_size + ONE_GIB))
  available="$(bytes_available "$WORKDIR")"

  if (( available < required )); then
    echo "Not enough tmpfs space for $(basename "$path"). Available: $(human_bytes "$available"), required: $(human_bytes "$required") (dump size + 1GiB)." >&2
    df -h "$WORKDIR"
    exit 1
  fi
}

discover_files() {
  local path base type date part rank
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
      printf "%s|%s|%010d|%s|%s|%s\n" "$rank" "$date" "$part" "$type" "$part" "$path"
    fi
  done | sort -t '|' -k1,1n -k2,2 -k3,3n
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
      if is_imported "$base"; then
        continue
      fi

      echo "Missing part $i for $type|$date, and it is not confirmed imported: $base" >&2
      return 1
    done
  done
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
    return 0
  fi

  if completed_in_cli_log "$base"; then
    log "SKIP already imported from CLI log: $base"
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
    log "FAILED import: $base exit=$rc"
    if grep -qiE "Signature verification failed|verification timed out" "$part_log"; then
      log "Signature verification failed or timed out for $base. Temporary files will be cleaned; retry may succeed."
    fi
    tail -n 80 "$part_log" || true
    cleanup_workdir_temp
    exit "$rc"
  fi

  if ! grep -q "Load dump successfully" "$part_log" && ! completed_in_cli_log "$base"; then
    if part_log_already_loaded "$part_log"; then
      log "SKIP already loaded according to reputationdb metadata validation: $base"
      record_imported "$path"
      cleanup_workdir_temp
      return 0
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
  load_latest_metadata_cursor
  ensure_workdir
  check_filesystem_space
  trap cleanup_workdir_temp EXIT
  cleanup_old_imported_dumps

  local plan_file
  plan_file="$(mktemp /tmp/rsdb_import_plan.XXXXXX)"
  discover_files > "$plan_file"

  if [[ ! -s "$plan_file" ]]; then
    log "No matching reputation dump files found in $SRC_DIR"
    rm -f "$plan_file"
    exit 0
  fi

  validate_contiguous_parts "$plan_file"

  log "Planned order:"
  while IFS='|' read -r _rank date _part_padded type part path; do
    if is_imported "$(basename "$path")"; then
      printf "  SKIP   %-4s %s part %s %s\n" "$type" "$date" "$part" "$path"
    else
      printf "  IMPORT %-4s %s part %s %s\n" "$type" "$date" "$part" "$path"
    fi
  done < "$plan_file"

  if [[ "$MODE" == "dry-run" ]]; then
    log "Dry run only; no imports executed."
    rm -f "$plan_file"
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
}

main
