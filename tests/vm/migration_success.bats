#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# The migration on the test VM, successful (m7-migration.md): old installations with systemd migrated
# through the real old stage one, and a failure after the new core started. See
# tests/vm/migration.bash. The tests run in order.

load ../unit/helpers
load github
load migration

# Subnets and ports: each file has ranges of its own, so files can run in parallel (tests/vm/run.sh
# -j); migration_success uses n from 115 and ports from 28000 (see the other files).

setup_file() {
  migrationSetupFile migration_success 115 28000
}

teardown_file() {
  migrationTeardownFile
}

@test "the real old stage one (cron's -a): migrated in place, the old installation gone" {
  local vol_before hm="$DIR/bin/SENERGY-Platform/mgw-host-manager" f
  vol_before="$(docker volume inspect -f '{{.CreatedAt}}' "mgw_${S}_mysqldb-data")"
  cp -a "$hm" "$BATS_TEST_TMPDIR/hm"
  run "$DIR/update.sh" -a
  echo "$output"
  [ "$status" -eq 0 ]
  migrated
  grep -qx autostart=true "$DIR/state/settings" && grep -qx secrets_size=100M "$DIR/state/settings"
  # the host-manager's data files, copied unchanged
  for f in "$BATS_TEST_TMPDIR/hm"/*.json*; do
    [ -e "$f" ] || continue
    cmp "$f" "$DIR/state/host-manager/${f##*/}"
  done
  # the old volumes are the new core's: same volume, not created again
  [ "$(docker volume inspect -f '{{.CreatedAt}}' "mgw_${S}_mysqldb-data")" = "$vol_before" ]
  # the units are links into current now, the old plain files gone
  [ -L "/etc/systemd/system/mgw_$S-core-manager.service" ] && [ -L "/etc/logrotate.d/mgw_${S}_core" ]
  systemctl is-enabled --quiet "mgw_$S-recover.service"
  systemctl is-active --quiet "mgw_$S-core-manager.service"
  [ "$(stat -f -c %T "/mnt/mgw_$S/secrets")" = "tmpfs" ]
  newRunning
  run "$DIR/current/ctrl.sh" status
  echo "$output"
  [[ "$output" == *"last update: success (migration $OLD_VERSION -> v0.40.0"* ]]
  # from now on the new stage one runs
  run "$DIR/current/update.sh" -a
  [ "$status" -eq 0 ]
  [[ "$output" == *"v0.40.0 is up to date"* ]]
}

@test "a failure after the new core started: no rollback, the new layout stays" {
  reinstallOld "$OLD_VERSION"
  run env MGW_TEST_FAIL_AT=started "$DIR/update.sh" -a
  echo "$output"
  [ "$status" -eq 1 ]
  grep -qx result=failed "$DIR/state/update" && grep -qx rolled_back=false "$DIR/state/update"
  [ "$(readlink "$DIR/current")" = "v0_40_0" ]
  ! grep -qx recovery_failed=true "$DIR/state/update"
  newRunning
}

# the oldest and the newest old release; v0.32.0 differs from v0.31.1 only in its stage two, which
# the migration never runs
@test "the other old releases migrate too" {
  local v
  for v in v0.30.0 v0.33.0-beta2; do
    reinstallOld "$v"
    [ "$(cat "$DIR/.version")" = "$v" ]
    run "$DIR/update.sh" -a
    echo "$v: $output"
    [ "$status" -eq 0 ]
    migrated
    grep -qx "from_version=$v" "$DIR/state/update"
    newRunning
  done
}
