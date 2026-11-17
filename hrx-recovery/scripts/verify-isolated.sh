#!/usr/bin/env bash
# Fresh loopback-only cluster, no access to the old database or production.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${PGBIN:?Set PGBIN to PostgreSQL 16+ bin directory}"
command -v mvn >/dev/null
command -v python3 >/dev/null
if [ "$(id -u)" = 0 ]; then echo 'Run the isolated cluster as a non-root user' >&2;exit 1;fi
mkdir -p "$ROOT/backend/target"
TEMP="$(mktemp -d)"
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
cleanup(){ "$PGBIN/pg_ctl" -D "$TEMP/data" -m immediate stop >/dev/null 2>&1 || true;rm -rf "$TEMP"; }
trap cleanup EXIT
"$PGBIN/initdb" -D "$TEMP/data" --auth=trust --no-locale -E UTF8 > "$TEMP/init.log"
"$PGBIN/pg_ctl" -D "$TEMP/data" -l "$TEMP/server.log" -o "-p $PORT -h 127.0.0.1 -k $TEMP" start
"$PGBIN/createdb" -h 127.0.0.1 -p "$PORT" hrx_test_recovery
"$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -d hrx_test_recovery -v ON_ERROR_STOP=1 -f "$ROOT/scripts/bootstrap.sql"
export HRX_TEST_DB_URL="jdbc:postgresql://127.0.0.1:$PORT/hrx_test_recovery"
export HRX_TEST_ADMIN_USER="$(id -un)" HRX_TEST_ADMIN_PASSWORD="" HRX_TEST_APP_PASSWORD="" HRX_TEST_MIGRATOR_PASSWORD=""
(cd "$ROOT/frontend" && npm ci && npm test && npm run build)
(cd "$ROOT/backend" && mvn -B clean verify)
# Recovery rehearsal preserves SQL metadata and privileges; file blobs require a separate backup.
"$PGBIN/pg_dump" -h 127.0.0.1 -p "$PORT" -Fc -f "$TEMP/recovery.dump" hrx_test_recovery
"$PGBIN/createdb" -h 127.0.0.1 -p "$PORT" hrx_test_restore
"$PGBIN/pg_restore" -h 127.0.0.1 -p "$PORT" --exit-on-error -d hrx_test_restore "$TEMP/recovery.dump"
"$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -d hrx_test_restore -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF (SELECT count(*) FROM hrx.flyway_schema_history WHERE type='SQL' AND success)<>9 THEN RAISE EXCEPTION 'Incomplete recovery migrations';END IF;
 IF has_table_privilege('hrx_recovery_app','hrx.supply_demand','UPDATE') OR has_column_privilege('hrx_recovery_app','hrx.supply_event','payload','SELECT') OR has_column_privilege('hrx_recovery_app','hrx.purchase_order_line','unit_price','SELECT') OR has_table_privilege('hrx_recovery_app','hrx.purchase_order','UPDATE') OR has_table_privilege('hrx_recovery_app','hrx.milestone_dependency','INSERT') OR has_table_privilege('hrx_recovery_app','hrx.milestone_dependency','UPDATE') OR has_table_privilege('hrx_recovery_app','hrx.delivery_milestone','UPDATE') OR has_table_privilege('hrx_recovery_app','hrx.delivery_milestone_event','INSERT') OR has_table_privilege('hrx_recovery_app','hrx.supply_followup','UPDATE') OR has_table_privilege('hrx_recovery_app','hrx.supply_followup_event','INSERT') THEN RAISE EXCEPTION 'Unsafe restored grants';END IF;
END $$;
SET ROLE hrx_recovery_app;
DO $$ BEGIN
 IF (SELECT count(*) FROM hrx.milestone_dependency)>0 OR (SELECT count(*) FROM hrx.delivery_milestone_progress)>0 OR (SELECT count(*) FROM hrx.delivery_milestone)>0 OR (SELECT count(*) FROM hrx.delivery_milestone_event)>0 OR (SELECT count(*) FROM hrx.supply_followup)>0 OR (SELECT count(*) FROM hrx.supply_followup_event)>0 OR (SELECT count(*) FROM hrx.supply_progress)>0 OR hrx.purchase_order_fulfillment(gen_random_uuid()) IS NOT NULL OR (SELECT count(*) FROM hrx.supply_demand)>0 OR (SELECT count(*) FROM hrx.controlled_file)>0 OR (SELECT count(*) FROM hrx.purchase_order)>0 OR (SELECT count(*) FROM hrx.purchase_order_lines(gen_random_uuid()))>0 THEN RAISE EXCEPTION 'Missing identity must deny restored records';END IF;
END $$;
SQL
echo 'PASS fresh recovery database, real tests, dump/restore and restricted runtime grants'
