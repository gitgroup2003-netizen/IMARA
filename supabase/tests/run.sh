#!/usr/bin/env bash
# Applies every migration to a scratch Postgres database and runs the checks.
# Needs psql access via the usual PG* environment variables.
set -euo pipefail
cd "$(dirname "$0")/.."
DB=imara_test
q() { psql -v ON_ERROR_STOP=1 -q -d "$1" "${@:2}"; }
q postgres -c "drop database if exists $DB" -c "create database $DB"
run() { echo "-> $1"; q $DB -f "$1" 2>&1 | grep -E "^(NOTICE|psql|ERROR)|FAIL" || true; }
q $DB -f tests/stubs.sql
q $DB -f migrations/0001_init.sql
q $DB -f tests/legacy.sql          # an account from before 0002
q $DB -f migrations/0002_multicurrency.sql
q $DB -f migrations/0003_rates_and_limits.sql
q $DB -f migrations/0004_service_categories.sql
q $DB -v ON_ERROR_STOP=1 -f tests/integration.sql 2>&1 | sed -n 's/^psql:.*NOTICE:  /  /p;/ERROR/p'
echo "database tests finished"
