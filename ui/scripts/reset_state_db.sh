#!/usr/bin/env bash
set -euo pipefail

explicit_path="${1:-}"
db_name="${DEPLOYDASH_DB_NAME:-deploydash_state.db}"

remove_db_files() {
  local db_path="$1"
  local removed=0

  if [[ -f "$db_path" ]]; then
    rm -f "$db_path"
    removed=1
  fi
  if [[ -f "${db_path}-wal" ]]; then
    rm -f "${db_path}-wal"
    removed=1
  fi
  if [[ -f "${db_path}-shm" ]]; then
    rm -f "${db_path}-shm"
    removed=1
  fi

  if [[ "$removed" -eq 1 ]]; then
    echo "Cleared: $db_path"
  fi
}

if [[ -n "$explicit_path" ]]; then
  remove_db_files "$explicit_path"
  exit 0
fi

data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
# Clears the Linux application-support root (DB, device identity, ssh/).
declare -a candidate_dirs=(
  "$data_home/com.deploydash.desktop"
  "$data_home/com.example.ui"
  "$data_home/com.example.desktop_app"
  "$data_home/ui"
  "$data_home/desktop_app"
  "$data_home/deploydash"
)

found=0
for dir in "${candidate_dirs[@]}"; do
  db_path="$dir/$db_name"
  if [[ -f "$db_path" || -f "${db_path}-wal" || -f "${db_path}-shm" ]]; then
    remove_db_files "$db_path"
    found=1
  fi
done

if [[ "$found" -eq 0 ]]; then
  echo "No SQLite state database files found for '$db_name'."
fi
