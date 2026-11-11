#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# The migration on the test VM, refusals and failures (m7-migration.md): an old installation of
# OLD_VERSION with systemd, the migration refused or failing in each phase, undone or rolled back to
# the old layout. See tests/vm/migration.bash. The tests run in order.

load ../unit/helpers
load github
load migration

# Subnets and ports: each file has ranges of its own, so files can run in parallel (tests/vm/run.sh
# -j); migration uses n from 105 and ports from 27000 (see the other files).

setup_file() {
  migrationSetupFile migration 105 27000
}

teardown_file() {
  migrationTeardownFile
}

@test "the old installation runs" {
  [ "$(cat "$DIR/.version")" = "$OLD_VERSION" ]
  [ -f "$DIR/.settings" ] && [ ! -e "$DIR/state" ]
  oldRunning
}

@test "a path that differs from the new layout: refused before anything changes" {
  cp "$DIR/.settings" "$BATS_TEST_TMPDIR/settings"
  sed -i "s|^log_path=.*|log_path=/var/log/mgw_$S|" "$DIR/.settings"
  run "$DIR/update.sh" -a
  cp "$BATS_TEST_TMPDIR/settings" "$DIR/.settings"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"log_path is '/var/log/mgw_$S', the new layout needs $DIR/log"* ]]
  [ "$(oldStatus result)" = "failed" ]
  [[ "$(oldStatus step)" == *"log_path is '/var/log/mgw_$S'"* ]]
  [ "$(oldStatus from_version)" = "$OLD_VERSION" ] && [ "$(oldStatus to_version)" = "v0.40.0" ]
  [ ! -e "$DIR/state" ]
  oldRunning
}

@test "an installation older than v0.30.0-alpha1: refused with the way forward" {
  echo v0.23.0 > "$DIR/.version"
  run "$DIR/update.sh" -a
  echo "$OLD_VERSION" > "$DIR/.version"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"older than v0.30.0-alpha1"* ]] && [[ "$output" == *"update it by hand"* ]]
  [[ "$(oldStatus step)" == *"older than v0.30.0-alpha1"* ]]
  [ ! -e "$DIR/state" ]
  oldRunning
}

@test "a held lock: the second run ends there, nothing changed" {
  mkdir "$DIR/state"
  flock "$DIR/state/lock" sleep 30 &
  local holder=$!
  sleep 1
  run "$DIR/update.sh" -a
  kill "$holder" 2> /dev/null || true
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"another update or migration of $DIR is running"* ]]
  [ ! -e "$DIR/state/update" ]
  nothingNew
  rm -rf "$DIR/state"
}

@test "a copy that doesn't match its checksums: undone, the old core untouched" {
  run env MGW_TEST_FAIL_AT=checksums "$DIR/update.sh" -a
  echo "$output"
  [ "$status" -eq 1 ]
  grep -qx result=failed "$DIR/state/update" && grep -qx kind=migration "$DIR/state/update"
  grep -qx rolled_back=false "$DIR/state/update" && grep -qx writer=v0_40_0 "$DIR/state/update"
  grep -q "^step=the copy of v0.40.0 doesn't match its checksums" "$DIR/state/update"
  [ ! -e "$DIR/state/attempts" ] || ! grep -q v0_40_0 "$DIR/state/attempts"
  [[ "$(oldStatus step)" == *"doesn't match its checksums"* ]]
  nothingNew
  oldRunning
}

@test "a failure while preparing: undone, the old core untouched" {
  run env MGW_TEST_FAIL_AT=prepare "$DIR/update.sh" -a
  echo "$output"
  [ "$status" -eq 1 ]
  grep -qx result=failed "$DIR/state/update" && grep -qx rolled_back=false "$DIR/state/update"
  grep -qx "step=preparing v0.40.0" "$DIR/state/update"
  [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=mgw_${S}_v0_40_0")" ]
  [ ! -e "$DIR/state/attempts" ] || ! grep -q v0_40_0 "$DIR/state/attempts"
  [[ "$(oldStatus step)" == *"preparing v0.40.0"* ]]
  nothingNew
  oldRunning
}

@test "a failure after the old core was stopped: rolled back to the old layout, counted" {
  run env MGW_TEST_FAIL_AT=activate "$DIR/update.sh" -a
  echo "$output"
  [ "$status" -eq 1 ]
  rolledBack
  grep -qx "step=activating v0_40_0" "$DIR/state/update"
  grep -qx version=v0_40_0 "$DIR/state/attempts" && grep -qx failures=1 "$DIR/state/attempts"
}

@test "a start that fails before a host binary started: rolled back" {
  run env MGW_TEST_FAIL_AT=start "$DIR/update.sh" -a
  echo "$output"
  [ "$status" -eq 1 ]
  rolledBack
  grep -q "^step=starting v0.40.0 (no host binary started)" "$DIR/state/update"
}

@test "a failing rollback: G9, nothing more attempted, restore.sh completes the new layout" {
  # by hand: the old stage one asks before it updates
  run bash -c 'echo y | MGW_TEST_FAIL_AT="activate rollback" "$DIR/update.sh"'
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"complete the new layout with $DIR/v0_40_0/restore.sh -path=$DIR"* ]]
  grep -qx recovery_failed=true "$DIR/state/update"
  [[ "$(oldStatus step)" == *"the rollback failed at"* ]]
  run "$DIR/v0_40_0/restore.sh" -path="$DIR" -y
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qx restored=true "$DIR/state/update"
  [ "$(readlink "$DIR/current")" = "v0_40_0" ]
  newRunning
}
