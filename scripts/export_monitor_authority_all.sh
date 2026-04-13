#!/usr/bin/env bash
set -euo pipefail

# ============================
# Global config
# ============================
OUT_BASE="/opt/Documentation/db_authority_exports"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BASE_DIR="${OUT_BASE}/authority_${TS}"

mkdir -p "${BASE_DIR}"

echo "▶ Exporting full DB authority snapshot to:"
echo "  ${BASE_DIR}"
echo

# ============================
# Helper: export one DB
# ============================
export_db () {
  local DB_LABEL="$1"
  local DB_CONTAINER="$2"
  local DB_NAME="$3"
  local DB_USER="$4"

  local OUT_DIR="${BASE_DIR}/${DB_LABEL}"
  mkdir -p "${OUT_DIR}"

  echo "=============================="
  echo "▶ Exporting ${DB_LABEL}"
  echo "▶ Container: ${DB_CONTAINER}"
  echo "▶ Database : ${DB_NAME}"
  echo "=============================="

  run_copy () {
    local sql="$1"
    local outfile="$2"

    docker exec -i "${DB_CONTAINER}" \
      psql -U "${DB_USER}" -d "${DB_NAME}" -At <<SQL \
      > "${OUT_DIR}/${outfile}"
${sql}
SQL
  }

  # 1. Schema-only dump
  echo "▶ Schema dump..."
  docker exec -i "${DB_CONTAINER}" \
    pg_dump -s -U "${DB_USER}" "${DB_NAME}" \
    > "${OUT_DIR}/${DB_NAME}.schema.sql"

  # 2. Tables
  echo "▶ Tables..."
  run_copy "
COPY (
  SELECT table_schema, table_name
  FROM information_schema.tables
  WHERE table_schema NOT IN ('pg_catalog','information_schema')
  ORDER BY table_schema, table_name
) TO STDOUT WITH CSV HEADER;
" "tables.csv"

  # 3. Columns
  echo "▶ Columns..."
  run_copy "
COPY (
  SELECT
    table_schema,
    table_name,
    ordinal_position,
    column_name,
    data_type,
    is_nullable,
    column_default
  FROM information_schema.columns
  WHERE table_schema NOT IN ('pg_catalog','information_schema')
  ORDER BY table_schema, table_name, ordinal_position
) TO STDOUT WITH CSV HEADER;
" "columns.csv"

  # 4. Foreign keys
  echo "▶ Foreign keys..."
  run_copy "
COPY (
  SELECT
    tc.table_schema,
    tc.table_name,
    kcu.column_name,
    ccu.table_schema AS foreign_table_schema,
    ccu.table_name   AS foreign_table_name,
    ccu.column_name  AS foreign_column_name,
    tc.constraint_name
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name
   AND tc.table_schema = kcu.table_schema
  JOIN information_schema.constraint_column_usage ccu
    ON ccu.constraint_name = tc.constraint_name
   AND ccu.table_schema = tc.table_schema
  WHERE tc.constraint_type = 'FOREIGN KEY'
  ORDER BY tc.table_schema, tc.table_name, tc.constraint_name
) TO STDOUT WITH CSV HEADER;
" "foreign_keys.csv"

  # 5. Schema-specific exports
  case "${DB_LABEL}" in

    monitor_metrics)
      echo "▶ manage_cfg tables..."
      for tbl in customers customer_halo_map modules pbx_modules trunk_modules pbx_customer_map; do
        run_copy "
        COPY (SELECT * FROM manage_cfg.${tbl})
        TO STDOUT WITH CSV HEADER;
        " "manage_cfg_${tbl}.csv"
      done

      echo "▶ admin views..."
      for view in v_customers v_customers_all v_pbx v_trunks; do
        run_copy "
        COPY (SELECT * FROM admin.${view})
        TO STDOUT WITH CSV HEADER;
        " "admin_${view}.csv"
      done

      echo "▶ admin view definitions..."
      docker exec -i "${DB_CONTAINER}" \
        psql -U "${DB_USER}" -d "${DB_NAME}" <<SQL \
        > "${OUT_DIR}/admin_views_definitions.sql"
\\pset pager off
\\d+ admin.v_customers
\\d+ admin.v_customers_all
\\d+ admin.v_pbx
\\d+ admin.v_trunks
SQL
      ;;

    monitor_secrets)
      echo "▶ core secrets tables..."
      for tbl in customers customer_modules encrypted_secrets pbx_3cx cdr_import_batches cdr_import_rejects; do
        run_copy "
        COPY (SELECT * FROM public.${tbl})
        TO STDOUT WITH CSV HEADER;
        " "public_${tbl}.csv"
      done
      ;;
  esac

  # README
  cat <<EOF > "${OUT_DIR}/README.md"
# ${DB_LABEL} authority export

Generated: ${TS} (UTC)

Database: ${DB_NAME}
Container: ${DB_CONTAINER}

Contents:
- ${DB_NAME}.schema.sql
- tables.csv
- columns.csv
- foreign_keys.csv
- schema-specific authority CSVs
- admin view definitions (if present)

Purpose:
This directory represents a read-only, authoritative snapshot of
${DB_LABEL} based solely on live database state.
EOF

  echo "✅ ${DB_LABEL} export complete"
  echo
}

# ============================
# Run exports
# ============================

export_db \
  "monitor_metrics" \
  "monitor-metrics-db" \
  "monitor_metrics" \
  "metrics_writer"

export_db \
  "monitor_secrets" \
  "monitor-secrets-db" \
  "monitor_secrets" \
  "secrets_admin"

echo "=============================="
echo "✅ ALL EXPORTS COMPLETE"
echo "📁 ${BASE_DIR}"
echo "=============================="