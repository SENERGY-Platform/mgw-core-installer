#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# The reconcile for logrotate, cron and avahi, against temporary /etc folders. Units need systemd and
# are tested on the VM (tests/vm/reconcile.bats); no unit files are used here, so systemctl isn't
# called.

load helpers

setup() {
  export ROOT="$BATS_TEST_TMPDIR/core" ETC="$BATS_TEST_TMPDIR/etc"
  export C="$ROOT/current/config"
  mkdir -p "$ROOT/v1_3_0/config/logrotate" "$ROOT/v1_3_0/config/cron" "$ROOT/v1_3_0/config/avahi" \
    "$ETC/systemd" "$ETC/logrotate.d" "$ETC/cron.daily" "$ETC/avahi"
  ln -s v1_3_0 "$ROOT/current"
  touch "$C/logrotate/mgw_abc_core" "$C/cron/mgw_abc_update" "$C/avahi/mgw_abc_core.service"
  printf '%s\n' 'core_name=' "systemd_path=$ETC/systemd" "logrotated_path=$ETC/logrotate.d" \
    "cron_path=$ETC/cron.daily" "avahi_path=$ETC/avahi" > "$BATS_TEST_TMPDIR/defaults"
  printf '%s\n' 'core_name=mgw_abc' > "$BATS_TEST_TMPDIR/settings"
}

reconcile() {
  dsh 'settingsLoad "$BATS_TEST_TMPDIR/defaults" "$BATS_TEST_TMPDIR/settings" || exit 9; reconcileEtc "$ROOT"' file settings reconcile
}

@test "creates a link through current for every file, under the file's name" {
  run reconcile
  [ "$status" -eq 0 ]
  [ "$(readlink "$ETC/logrotate.d/mgw_abc_core")" = "$C/logrotate/mgw_abc_core" ]
  [ "$(readlink "$ETC/cron.daily/mgw_abc_update")" = "$C/cron/mgw_abc_update" ]
  [ "$(readlink "$ETC/avahi/mgw_abc_core.service")" = "$C/avahi/mgw_abc_core.service" ]
}

@test "a second run changes nothing" {
  reconcile
  run reconcile
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "a switched integration loses its link" {
  reconcile
  rm -r "$ROOT/v1_3_0/config/avahi"
  run reconcile
  [ "$status" -eq 0 ]
  [ ! -L "$ETC/avahi/mgw_abc_core.service" ]
  [ -L "$ETC/cron.daily/mgw_abc_update" ]
}

@test "switching current to a version with other files: links follow, no diff needed" {
  reconcile
  mkdir -p "$ROOT/v1_4_0/config/logrotate" "$ROOT/v1_4_0/config/cron"
  touch "$ROOT/v1_4_0/config/logrotate/mgw_abc_core" "$ROOT/v1_4_0/config/cron/mgw_abc_update" "$ROOT/v1_4_0/config/cron/mgw_abc_extra"
  ln -sfn v1_4_0 "$ROOT/current"
  run reconcile
  [ "$status" -eq 0 ]
  [ -L "$ETC/cron.daily/mgw_abc_extra" ]
  [ ! -L "$ETC/avahi/mgw_abc_core.service" ]
  [ "$(readlink -f "$ETC/cron.daily/mgw_abc_update")" = "$ROOT/v1_4_0/config/cron/mgw_abc_update" ]
}

@test "a half-done earlier reconcile is completed" {
  ln -s "$C/cron/mgw_abc_update" "$ETC/cron.daily/mgw_abc_update"
  ln -s "$C/avahi/mgw_abc_gone.service" "$ETC/avahi/mgw_abc_gone.service"
  run reconcile
  [ "$status" -eq 0 ]
  [ -L "$ETC/logrotate.d/mgw_abc_core" ]
  [ ! -L "$ETC/avahi/mgw_abc_gone.service" ]
}

@test "a link of ours under the wrong name is replaced" {
  ln -s "$C/cron/mgw_abc_update" "$ETC/cron.daily/old_name_update"
  run reconcile
  [ "$status" -eq 0 ]
  [ ! -L "$ETC/cron.daily/old_name_update" ]
  [ -L "$ETC/cron.daily/mgw_abc_update" ]
}

@test "foreign files and links are never touched" {
  echo foreign > "$ETC/cron.daily/other_job"
  ln -s /usr/share/foo "$ETC/cron.daily/other_link"
  ln -s "$BATS_TEST_TMPDIR/other_core/current/config/cron/other_core_update" "$ETC/cron.daily/other_core_update"
  echo mine-but-plain > "$ETC/logrotate.d/mgw_abc_core"
  run reconcile
  [ "$status" -eq 1 ]
  [[ "$output" == *"mgw_abc_core exists and isn't ours, leaving it alone"* ]]
  [ "$(cat "$ETC/cron.daily/other_job")" = "foreign" ]
  [ "$(readlink "$ETC/cron.daily/other_link")" = "/usr/share/foo" ]
  [ -L "$ETC/cron.daily/other_core_update" ]
  [ "$(cat "$ETC/logrotate.d/mgw_abc_core")" = "mine-but-plain" ]
  # the rest is still done
  [ -L "$ETC/cron.daily/mgw_abc_update" ]
}

@test "without current's config nothing is removed" {
  reconcile
  rm "$ROOT/current"
  run reconcile
  [ "$status" -eq 1 ]
  [[ "$output" == *"not reconciling"* ]]
  [ -L "$ETC/cron.daily/mgw_abc_update" ]
}

@test "a missing /etc folder is reported, the others are done" {
  rmdir "$ETC/avahi"
  run reconcile
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot link mgw_abc_core.service"* ]]
  [ -L "$ETC/cron.daily/mgw_abc_update" ]
}

@test "the cron link runs through run-parts" {
  if ! command -v run-parts > /dev/null; then skip "no run-parts"; fi
  printf '%s\n' '#!/bin/sh' "touch $BATS_TEST_TMPDIR/ran" > "$C/cron/mgw_abc_update"
  chmod 755 "$C/cron/mgw_abc_update"
  reconcile
  run-parts "$ETC/cron.daily"
  [ -e "$BATS_TEST_TMPDIR/ran" ]
}
