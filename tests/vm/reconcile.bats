#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# The reconcile of unit links against the real /etc/systemd/system and systemd. Runs as root on the
# test VM (sudo bats tests/vm). Each test uses its own core name and removes everything it created.

load ../unit/helpers

setup() {
  export CORE="mgwt$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  # not in /tmp: linked unit files have to be on the root file system (PLAN.md 5)
  export ROOT="/var/tmp/$CORE" ETC="$BATS_TEST_TMPDIR/etc"
  mkdir -p "$ETC/logrotate.d" "$ETC/cron.daily" "$ETC/avahi"
  printf '%s\n' 'core_name=' 'systemd_path=/etc/systemd/system' "logrotated_path=$ETC/logrotate.d" \
    "cron_path=$ETC/cron.daily" "avahi_path=$ETC/avahi" > "$BATS_TEST_TMPDIR/defaults"
  printf '%s\n' "core_name=$CORE" > "$BATS_TEST_TMPDIR/settings"
  version v1_3_0 a b
  ln -s v1_3_0 "$ROOT/current"
}

teardown() {
  local unit
  for unit in /etc/systemd/system/"$CORE"-*; do
    [ -e "$unit" ] || [ -L "$unit" ] || continue
    systemctl disable "${unit##*/}" > /dev/null 2>&1 || true
    rm -f "$unit"
  done
  find /etc/systemd/system -mindepth 2 -maxdepth 2 -name "$CORE-*" -delete
  systemctl daemon-reload
  rm -rf "$ROOT"
}

# creates the version folder $1 with the service units $2.. (sleeping services)
version() {
  local v="$1" unit
  shift
  mkdir -p "$ROOT/$v/config/systemd-units/services"
  for unit in "$@"; do
    printf '%s\n' '[Unit]' "Description=$CORE $unit $v" '[Service]' 'ExecStart=/bin/sleep infinity' \
      '[Install]' 'WantedBy=default.target' > "$ROOT/$v/config/systemd-units/services/$CORE-$unit.service"
  done
}

reconcile() {
  dsh 'settingsLoad "$BATS_TEST_TMPDIR/defaults" "$BATS_TEST_TMPDIR/settings" || exit 9; reconcileEtc "$ROOT"' file settings reconcile
}

description() {
  systemctl show -p Description --value "$CORE-$1.service"
}

@test "units are linked through current, loaded and enabled" {
  run reconcile
  [ "$status" -eq 0 ]
  [ "$(readlink "/etc/systemd/system/$CORE-a.service")" = "$ROOT/current/config/systemd-units/services/$CORE-a.service" ]
  [ "$(systemctl is-enabled "$CORE-a.service")" = "enabled" ]
  [ "$(systemctl is-enabled "$CORE-b.service")" = "enabled" ]
  [ "$(description a)" = "$CORE a v1_3_0" ]
}

@test "after switching current, the units have the new version's content" {
  reconcile
  version v1_4_0 a b
  ln -sfn v1_4_0 "$ROOT/current"
  run reconcile
  [ "$status" -eq 0 ]
  [ "$(description a)" = "$CORE a v1_4_0" ]
  [ "$(systemctl is-enabled "$CORE-a.service")" = "enabled" ]
}

@test "a unit the new version adds is linked and enabled, one it drops is disabled and removed" {
  reconcile
  version v1_4_0 a c
  ln -sfn v1_4_0 "$ROOT/current"
  run reconcile
  [ "$status" -eq 0 ]
  [ "$(systemctl is-enabled "$CORE-c.service")" = "enabled" ]
  [ ! -L "/etc/systemd/system/$CORE-b.service" ]
  [ -z "$(find /etc/systemd/system -name "$CORE-b.service")" ]
}

@test "a rollback (current pointing back) restores the old set" {
  reconcile
  version v1_4_0 a c
  ln -sfn v1_4_0 "$ROOT/current"
  reconcile
  ln -sfn v1_3_0 "$ROOT/current"
  run reconcile
  [ "$status" -eq 0 ]
  [ "$(systemctl is-enabled "$CORE-b.service")" = "enabled" ]
  [ ! -L "/etc/systemd/system/$CORE-c.service" ]
  [ -z "$(find /etc/systemd/system -name "$CORE-c.service")" ]
  [ "$(description a)" = "$CORE a v1_3_0" ]
}

@test "a linked but not enabled unit is enabled" {
  ln -s "$ROOT/current/config/systemd-units/services/$CORE-a.service" "/etc/systemd/system/$CORE-a.service"
  run reconcile
  [ "$status" -eq 0 ]
  [ "$(systemctl is-enabled "$CORE-a.service")" = "enabled" ]
}

@test "a dropped unit whose file is gone is still disabled" {
  reconcile
  version v1_4_0 a
  ln -sfn v1_4_0 "$ROOT/current"
  rm -r "$ROOT/v1_3_0"
  run reconcile
  [ "$status" -eq 0 ]
  [ ! -L "/etc/systemd/system/$CORE-b.service" ]
  [ -z "$(find /etc/systemd/system -name "$CORE-b.service")" ]
}

@test "core-owned plain unit files are left alone" {
  printf '%s\n' '[Service]' 'Type=oneshot' 'ExecStart=/bin/true' '[Install]' 'WantedBy=default.target' \
    > "/etc/systemd/system/$CORE-recover.service"
  systemctl daemon-reload
  systemctl enable "$CORE-recover.service" > /dev/null 2>&1
  run reconcile
  [ "$status" -eq 0 ]
  [ -f "/etc/systemd/system/$CORE-recover.service" ] && [ ! -L "/etc/systemd/system/$CORE-recover.service" ]
  [ "$(systemctl is-enabled "$CORE-recover.service")" = "enabled" ]
}

@test "units are enabled, not started" {
  run reconcile
  [ "$(systemctl is-active "$CORE-a.service")" != "active" ]
}
