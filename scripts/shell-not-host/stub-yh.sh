#!/bin/sh
# A stand-in for `yh`, for check_shell_not_host.py's --engine-stub self-test only. It is not the Engine:
# it proves the harness and the app's detached launch, never a Night.
#
# `rehearse --project <id>` prints `yh rehearse`'s progress lines and writes a minimal Journal at
# $YH_STUB_CONFIGURATION_DIRECTORY/journals/<id>.db: one Night with a Night Card, and for each Act an
# Act lease held for $YH_STUB_ACT_SECONDS (default 2), an event, and a Board write to the Night Card.
# A rollback journal, not WAL: the harness polls it read-only between these one-shot sqlite3 calls.
# Every run mints its own identifiers and timestamps, as two real Nights would.
# `recalibrate` prints nothing and fails, which the Recalibrate tab shows without blocking the rehearsal.

set -eu

case "${1:-}" in
  rehearse) ;;
  *) exit 1 ;;
esac
project="$3"
journal="$YH_STUB_CONFIGURATION_DIRECTORY/journals/$project.db"
mkdir -p "$(dirname "$journal")"

now() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }
uuid() { uuidgen | tr 'A-Z' 'a-z'; }
card="$(uuid)"

sqlite3 "$journal" <<SQL
CREATE TABLE night (id INTEGER PRIMARY KEY AUTOINCREMENT, mode TEXT NOT NULL, state TEXT NOT NULL,
  night_card_issue_id TEXT, opened_at TEXT NOT NULL);
CREATE TABLE act_lease (id INTEGER PRIMARY KEY CHECK (id = 1), act TEXT NOT NULL, run_id TEXT NOT NULL,
  claimed_at TEXT NOT NULL);
CREATE TABLE event (id INTEGER PRIMARY KEY AUTOINCREMENT, night_id INTEGER, act TEXT, run_id TEXT,
  type TEXT NOT NULL, occurred_at TEXT NOT NULL, payload TEXT);
CREATE TABLE outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, client_id TEXT NOT NULL UNIQUE, issue_id TEXT,
  operation TEXT NOT NULL, payload TEXT NOT NULL, created_at TEXT NOT NULL);
INSERT INTO night (mode, state, night_card_issue_id, opened_at) VALUES ('rehearsal', 'opened', '$card', '$(now)');
SQL

for act in author build land; do
  echo "rehearsal Night: running the $act Act"
  run="$(uuid)"
  sqlite3 "$journal" "INSERT INTO act_lease (id, act, run_id, claimed_at) VALUES (1, '$act', '$run', '$(now)');"
  sleep "${YH_STUB_ACT_SECONDS:-2}"
  sqlite3 "$journal" <<SQL
INSERT INTO event (night_id, act, run_id, type, occurred_at, payload)
  VALUES (1, '$act', '$run', 'ActFinished', '$(now)', '{"project":"$project"}');
INSERT INTO outbox (client_id, issue_id, operation, payload, created_at)
  VALUES ('$(uuid)', '$card', 'descriptionRewrite', '{"line":"$act finished for $project"}', '$(now)');
DELETE FROM act_lease;
SQL
  echo "rehearsal Night: the $act Act finished"
done
sqlite3 "$journal" "UPDATE night SET state = 'completed';"
