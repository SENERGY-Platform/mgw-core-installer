#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# The migration on the test VM without systemd (m7-migration.md, migration.md decision 6): the old
# host binaries started by the old ctrl.sh and recorded in .pid. See tests/vm/migration.bash. The
# tests run in order.

load ../unit/helpers
load github
load migration

# Subnets and ports: each file has ranges of its own, so files can run in parallel (tests/vm/run.sh
# -j); migration_nosystemd uses n from 125 and ports from 29000 (see the other files).

setup_file() {
  migrationSetupFile migration_nosystemd 125 29000 false
}

teardown_file() {
  migrationTeardownFile
}

@test "the old processes stopped, the new ones started detached" {
  oldRunning
  local old_pids p
  old_pids="$(cat "$DIR/.pid")"
  run "$DIR/update.sh" -a
  echo "$output"
  [ "$status" -eq 0 ]
  migrated
  grep -qx autostart=false "$DIR/state/settings"
  for p in $old_pids; do ! kill -0 "$p" 2> /dev/null; done
  [ -s "$DIR/state/pid" ]
  [ ! -e "/etc/systemd/system/mgw_$S-recover.service" ]
  newRunning
}

@test "a rollback: the old ctrl.sh starts the old core again" {
  reinstallOld "$OLD_VERSION" false
  run env MGW_TEST_FAIL_AT=activate "$DIR/update.sh" -a
  echo "$output"
  [ "$status" -eq 1 ]
  rolledBack
  # the old processes the old ctrl.sh started don't hold the lock
  flock -w 2 "$DIR/state/lock" true
}
