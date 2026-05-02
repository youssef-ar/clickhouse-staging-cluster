#!/bin/bash

set -euo pipefail

CH_HOST="localhost"
CH_PORT="9000"
CH_USER="default"
CH_PASSWORD=""
DRY_RUN=false
LOG_FILE="migration_$(date +%Y%m%d_%H%M%S).log"

usage() {
  echo "Usage: $0 [--host HOST] [--port PORT] [--user USER] [--password PASSWORD] [--dry-run]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)     CH_HOST="$2";     shift 2 ;;
    --port)     CH_PORT="$2";     shift 2 ;;
    --user)     CH_USER="$2";     shift 2 ;;
    --password) CH_PASSWORD="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true;     shift   ;;
    *) usage ;;
  esac
done

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

ch_query() {
  clickhouse-client \
    --host "$CH_HOST" \
    --port "$CH_PORT" \
    --user "$CH_USER" \
    --password "$CH_PASSWORD" \
    --query "$1"
}

ch_query_fmt() {
  clickhouse-client \
    --host "$CH_HOST" \
    --port "$CH_PORT" \
    --user "$CH_USER" \
    --password "$CH_PASSWORD" \
    --format TabSeparated \
    --query "$1"
}

run_sql() {
  local label="$1"
  local sql="$2"
  if [ "$DRY_RUN" = true ]; then
    log "[DRY-RUN] $label"
    log "  SQL: $sql"
  else
    log "Running: $label"
    ch_query "$sql"
    log "Done: $label"
  fi
}

log "======================================================="
log " ClickHouse Replication Path Migration"
log " Host: $CH_HOST:$CH_PORT | Dry-run: $DRY_RUN"
log "======================================================="

log "Checking connection..."
ch_query "SELECT 1" > /dev/null
log "Connection OK"

log "Current node macros:"
ch_query_fmt "SELECT macro, substitution FROM system.macros" | tee -a "$LOG_FILE"

# Fetch all tables to migrate

log "Fetching tables to migrate..."

TABLES=$(ch_query_fmt "
  SELECT database, \`table\`
  FROM system.replicas
  WHERE database LIKE 'reporting%'
    AND zookeeper_path NOT LIKE concat('%/', database, '.', \`table\`, '%')
  GROUP BY database, \`table\`
  ORDER BY database, \`table\`
")

TABLE_COUNT=$(echo "$TABLES" | grep -c . || true)
log "Found $TABLE_COUNT tables to migrate"

if [ "$TABLE_COUNT" -eq 0 ]; then
  log "No tables found. Exiting."
  exit 0
fi

# Migrate each table

SUCCESS=0
FAILED=0
FAILED_TABLES=""

while IFS=$'\t' read -r DB TBL; do
  log "-------------------------------------------------------"
  log "Migrating: $DB.$TBL"

  NEW_TABLE="${TBL}_new"
  NEW_PATH="/clickhouse/tables/${DB}.${TBL}/{shard}"

  # Step 1: Check if _new table already exists (resume support)
  EXISTS=$(ch_query_fmt "
    SELECT count()
    FROM system.tables
    WHERE database = '$DB' AND name = '$NEW_TABLE'
  ")

  if [ "$EXISTS" -eq 0 ]; then
    # Step 2: Create new table with correct engine path
    run_sql "Create $DB.$NEW_TABLE with correct Keeper path" "
      CREATE TABLE ${DB}.${NEW_TABLE}
      AS ${DB}.${TBL}
      ENGINE = ReplicatedMergeTree('${NEW_PATH}', '{replica}')
      ORDER BY Period_date_start
      SETTINGS index_granularity = 8192
    "
  else
    log "Table $DB.$NEW_TABLE already exists — resuming from data copy step"
  fi

  # Step 3: Record timestamp before copy (for delta catch-up)
  COPY_START=$(date -u '+%Y-%m-%d %H:%M:%S')
  log "Copy start timestamp: $COPY_START"

  # Step 4: Copy existing data (old table stays live)
  OLD_COUNT=$(ch_query_fmt "SELECT count() FROM ${DB}.${TBL}")
  log "Source row count: $OLD_COUNT"

  run_sql "Copy data from $DB.$TBL to $DB.$NEW_TABLE" "
    INSERT INTO ${DB}.${NEW_TABLE}
    SELECT * FROM ${DB}.${TBL}
  "

  # Step 5: Copy delta (rows inserted during the copy)
  run_sql "Copy delta rows inserted after $COPY_START" "
    INSERT INTO ${DB}.${NEW_TABLE}
    SELECT * FROM ${DB}.${TBL}
    WHERE Created_at >= '${COPY_START}'
  "

  # Step 6: Verify row counts match
  if [ "$DRY_RUN" = false ]; then
    NEW_COUNT=$(ch_query_fmt "SELECT count() FROM ${DB}.${NEW_TABLE}")
    log "New table row count: $NEW_COUNT (source was $OLD_COUNT)"

    if [ "$NEW_COUNT" -lt "$OLD_COUNT" ]; then
      log "ERROR: Row count mismatch for $DB.$TBL — skipping exchange. Manual check required."
      FAILED=$((FAILED + 1))
      FAILED_TABLES="$FAILED_TABLES\n  $DB.$TBL"
      continue
    fi
  fi

  # Step 7: Atomic swap 
  run_sql "EXCHANGE TABLES $DB.$TBL and $DB.$NEW_TABLE" "
    EXCHANGE TABLES ${DB}.${TBL} AND ${DB}.${NEW_TABLE}
  "

  # Step 8: Drop old table (now named _new after the swap)
  run_sql "Drop old table $DB.$NEW_TABLE" "
    DROP TABLE ${DB}.${NEW_TABLE}
  "

done <<< "$TABLES"

# Final report

log "======================================================="
log " Migration complete"
log " Succeeded: $SUCCESS"
log " Failed:    $FAILED"
if [ -n "$FAILED_TABLES" ]; then
  log " Failed tables:"
  echo -e "$FAILED_TABLES" | tee -a "$LOG_FILE"
fi
log " Full log: $LOG_FILE"
log "======================================================="

# Final status based on migration results

if [ "$FAILED" -eq 0 ]; then
  log "Migration successful: all tables migrated without errors."
  exit 0
else
  log "Migration completed with errors."
  log "Failed tables:"
  echo -e "$FAILED_TABLES" | tee -a "$LOG_FILE"
  exit 1
fi
