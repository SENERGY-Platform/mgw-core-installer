#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# Interrupted migrations on the test VM (m7-migration.md, finding 8): a migration killed in each
# window (MGW_TEST_KILL_AT, like a power loss), then recovered by whoever finds it: the next old stage
# one run, the old update.sh by hand, the new update.sh. The boot recovery needs a reboot and is tested
# by hand (decision 9). See tests/vm/migration.bash. The tests run in order.

load ../unit/helpers
load github
load migration

# Subnets and ports: each file has ranges of its own, so files can run in parallel (tests/vm/run.sh
# -j); migration_interrupted uses n from 130 and ports from 30000 (see the other files).

setup_file() {
  migrationSetupFile migration_interrupted 130 30000
}

teardown_file() {
  migrationTeardownFile
}

# kills the migration at the step $1, leaving the record running in the phase $2. Each recovered
# rollback counts towards the retry limit (G8); the tests start each with a clean count.
killAt() {
  rm -f "$DIR/state/attempts"
  run env MGW_TEST_KILL_AT="$1" "$DIR/update.sh" -a
  grep -qx result=running "$DIR/state/update" && grep -qx "phase=$2" "$DIR/state/update"
}

# the next old stage one run finds the interrupted migration, recovers it and migrates again; that
# migration fails while preparing (MGW_TEST_FAIL_AT=prepare), so the old installation stays for the
# next test. Its output tells what the recovery did.
nextRun() {
  run env MGW_TEST_FAIL_AT=prepare "$DIR/update.sh" -a
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"an interrupted migration to v0.40.0 was found (phase $1), recovering it first"* ]]
  grep -qx "step=preparing v0.40.0" "$DIR/state/update"
  nothingNew
  oldRunning
}

@test "killed right after the record, before the copy: undone by the next run without the writer's folder" {
  killAt copying preparing
  [ ! -e "$DIR/v0_40_0_tmp" ] || rm -rf "$DIR/v0_40_0_tmp"
  nextRun preparing
}

@test "killed after the copy: the writer's recover.sh undoes it" {
  killAt copied preparing
  [ -d "$DIR/v0_40_0_tmp" ]
  nextRun preparing
  [[ "$output" == *"undoing the interrupted migration (preparing)"* ]]
}

@test "killed after state/settings was written: undone" {
  killAt settings preparing
  [ -f "$DIR/state/settings" ]
  nextRun preparing
}

@test "killed when switching, the old core still running: rolled back" {
  killAt switching switching
  nextRun switching
  [[ "$output" == *"rolling back to the old installation"* ]]
}

@test "killed after the old core was stopped: rolled back, the old core started again" {
  killAt stopped switching
  ! systemctl is-active --quiet "mgw_$S-core-manager.service"
  nextRun switching
}

@test "killed after the old files in /etc were moved aside: put back, rolled back" {
  killAt moved switching
  [ ! -e "/etc/systemd/system/mgw_$S-core-manager.service" ]
  nextRun switching
  [ -f "/etc/logrotate.d/mgw_${S}_core" ] && [ ! -L "/etc/logrotate.d/mgw_${S}_core" ]
}

@test "killed after current was activated, the old update.sh by hand: recovered through current, rolled back" {
  killAt activated switching
  [ -L "$DIR/current" ]
  run bash -c 'echo y | "$DIR/update.sh"'
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the interrupted migration of $DIR was rolled back"* ]]
  grep -qx result=failed "$DIR/state/update" && grep -qx rolled_back=true "$DIR/state/update"
  grep -qx interrupted=true "$DIR/state/update"
  grep -q "^warning=interrupted, recovered by update.sh from " "$DIR/state/update"
  nothingNew
  oldRunning
}

@test "killed when starting, the new update.sh: past the point of no return, recorded, the new layout stays" {
  killAt starting starting
  run "$DIR/current/update.sh" -a
  echo "$output"
  grep -qx result=failed "$DIR/state/update" && grep -qx rolled_back=false "$DIR/state/update"
  grep -qx interrupted=true "$DIR/state/update" && grep -qx kind=migration "$DIR/state/update"
  [ "$(readlink "$DIR/current")" = "v0_40_0" ]
  run "$DIR/current/ctrl.sh" start
  [ "$status" -eq 0 ]
  newRunning
}

@test "killed during the cleanup: the new update.sh's recovery repeats it" {
  reinstallOld "$OLD_VERSION"
  run env MGW_TEST_KILL_AT=cleaning "$DIR/update.sh" -a
  grep -qx result=success "$DIR/state/update" && grep -qx "step=cleaning up" "$DIR/state/update"
  [ -e "$DIR/.settings" ]
  run "$DIR/current/update.sh" -a
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"repeating the interrupted cleanup of the migration"* ]]
  grep -q "^warning=the cleanup was interrupted, repeated by" "$DIR/state/update"
  # the recovery doesn't know the old stage one's work folder; /tmp is cleared at the next boot
  rm -rf "$WORK"
  migrated
  newRunning
}

@test "a second old stage one during a migration: it ends at the lock, the first one finishes" {
  reinstallOld "$OLD_VERSION"
  "$DIR/update.sh" -a > "$BATS_TEST_TMPDIR/first.log" 2>&1 &
  local first=$! i=0
  # until the first run works from its copy in the install directory: it no longer needs the work
  # folder the second old stage one deletes
  while ! grep -qx "step=preparing v0.40.0" "$DIR/state/update" 2> /dev/null; do
    sleep 0.5
    i=$((i + 1))
    [ $i -lt 240 ]
  done
  run "$DIR/update.sh" -a
  echo "$output"
  # it ends at the lock: in migration.sh, or, if the first one got as far as current already, in the
  # recovery the new update.sh runs for an old update.sh
  if [[ "$output" == *"another update or migration of $DIR is running"* ]]; then
    [ "$status" -eq 0 ]
  else
    [[ "$output" == *"the lock is held, its holder is responsible"* ]]
  fi
  wait "$first"
  cat "$BATS_TEST_TMPDIR/first.log"
  migrated
  newRunning
}
