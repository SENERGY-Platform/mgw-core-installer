#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# Starting and stopping the core, with and without systemd, on the test VM. The host binaries are
# fakebin (tests/vm/fakebin, built by tests/vm/run.sh). Each test uses its own core name and removes
# everything it created.

load ../unit/helpers

REPOS="SENERGY-Platform/mgw-container-engine-wrapper SENERGY-Platform/mgw-host-manager SENERGY-Platform/mgw-core-manager"

setup() {
  FAKEBIN="$BATS_TEST_DIRNAME/fakebin/fakebin"
  [ -x "$FAKEBIN" ] || { echo "no fakebin, run the VM tests with tests/vm/run.sh" >&2; return 1; }
  export CORE="mgwt$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  export ROOT="/var/tmp/$CORE" SECRETS="/mnt/$CORE/secrets"
  local repo
  for repo in $REPOS; do
    mkdir -p "$ROOT/v1_3_0/bin/$repo" "$ROOT/v1_3_0/config/host-binaries/$repo"
    cp "$FAKEBIN" "$ROOT/v1_3_0/bin/$repo/bin"
    echo '{}' > "$ROOT/v1_3_0/config/host-binaries/$repo/conf.json"
  done
  mkdir -p "$ROOT/log" "$ROOT/state"
  ln -s v1_3_0 "$ROOT/current"
  export host_logrotated_path="$BATS_TEST_TMPDIR" host_cron_path="$BATS_TEST_TMPDIR" host_avahi_path="$BATS_TEST_TMPDIR"
  printf '%s\n' 'core_name=' 'autostart=false' 'secrets_size=16M' > "$BATS_TEST_TMPDIR/defaults"
  printf '%s\n' "core_name=$CORE" > "$BATS_TEST_TMPDIR/settings"
}

teardown() {
  local unit
  for unit in /etc/systemd/system/"$CORE"-* /etc/systemd/system/mnt-"$CORE"-secrets.mount; do
    [ -e "$unit" ] || [ -L "$unit" ] || continue
    systemctl stop "${unit##*/}" > /dev/null 2>&1 || true
    systemctl disable "${unit##*/}" > /dev/null 2>&1 || true
    rm -f "$unit"
  done
  find /etc/systemd/system -mindepth 2 -maxdepth 2 \( -name "$CORE-*" -o -name "mnt-$CORE-*" \) -delete
  systemctl daemon-reload
  pkill -KILL -f "^$ROOT/" 2> /dev/null || true
  umount "$SECRETS" 2> /dev/null || true
  rm -rf "$ROOT" "/mnt/$CORE"
}

core() {
  dsh 'settingsLoad "$BATS_TEST_TMPDIR/defaults" "$BATS_TEST_TMPDIR/settings" || exit 9; '"$1" file settings state lock host reconcile core
}

# the pids of the running fake host binaries of this core
procs() {
  pgrep -f "^$ROOT/current/bin/" | sort
}

with_systemd() {
  echo 'autostart=true' >> "$BATS_TEST_TMPDIR/settings"
  mkdir -p "$ROOT/v1_3_0/config/systemd-units/services"
  local repo name
  for repo in $REPOS; do
    name="${repo#SENERGY-Platform/mgw-}"
    printf '%s\n' '[Unit]' "Description=$CORE $name" '[Service]' \
      "ExecStart=$ROOT/current/bin/$repo/bin -config=$ROOT/current/config/host-binaries/$repo/conf.json" \
      '[Install]' 'WantedBy=default.target' > "$ROOT/v1_3_0/config/systemd-units/services/$CORE-$name.service"
  done
  printf '%s\n' '[Mount]' 'Type=tmpfs' 'What=tmpfs' "Where=$SECRETS" 'Options=nosuid,nodev,noexec,mode=1777,size=16M' \
    > "/etc/systemd/system/mnt-$CORE-secrets.mount"
  core 'reconcileEtc "$ROOT"' > /dev/null
}

@test "without systemd: start runs the binaries detached and records them" {
  run core 'coreStart "$ROOT"'
  [ "$status" -eq 0 ]
  [ "$(procs | wc -l)" -eq 3 ]
  [ "$(sort "$ROOT/state/pid")" = "$(procs)" ]
  # each runs through current with its config, in its own session
  pid="$(pgrep -f "^$ROOT/current/bin/SENERGY-Platform/mgw-core-manager/bin")"
  [ "$(tr '\0' ' ' < "/proc/$pid/cmdline")" = "$ROOT/current/bin/SENERGY-Platform/mgw-core-manager/bin -config=$ROOT/current/config/host-binaries/SENERGY-Platform/mgw-core-manager/conf.json " ]
  [ "$(ps -o sid= -p "$pid" | tr -d ' ')" = "$pid" ]
  run core 'coreRunning "$ROOT"'
  [ "$status" -eq 0 ]
}

@test "without systemd: a binary that exits right away fails the start" {
  printf '%s\n' '#!/bin/sh' 'exit 1' > "$ROOT/v1_3_0/bin/SENERGY-Platform/mgw-host-manager/bin"
  run core 'coreStart "$ROOT"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"host binaries not running: SENERGY-Platform/mgw-host-manager"* ]]
}

@test "without systemd: the secrets tmpfs is mounted, the plain directory cleared first" {
  mkdir -p "$SECRETS"
  echo leftover > "$SECRETS/old-secret"
  run core 'coreStart "$ROOT"'
  [ "$status" -eq 0 ]
  [ "$(findmnt -n -o FSTYPE "$SECRETS")" = "tmpfs" ]
  [[ "$(findmnt -n -o OPTIONS "$SECRETS")" == *"size=16384k"* ]]
  echo live > "$SECRETS/live-secret"
  run core 'coreStop "$ROOT" && coreStart "$ROOT"'
  # a mounted tmpfs is never cleared, and stop leaves it mounted
  [ "$(cat "$SECRETS/live-secret")" = "live" ]
  umount "$SECRETS"
  [ -z "$(ls -A "$SECRETS")" ]
}

@test "without systemd: a second start reports the running core" {
  core 'coreStart "$ROOT"'
  before="$(procs)"
  run core 'coreStart "$ROOT"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"host binaries already running"* ]]
  [ "$(procs)" = "$before" ]
}

@test "without systemd: an incomplete set is restarted" {
  core 'coreStart "$ROOT"'
  pkill -f "^$ROOT/current/bin/SENERGY-Platform/mgw-host-manager/bin"
  sleep 0.2
  run core 'coreStart "$ROOT"'
  [[ "$output" == *"stopping an incomplete set"* ]]
  [ "$(procs | wc -l)" -eq 3 ]
}

@test "without systemd: stop ends the binaries and removes state/pid" {
  core 'coreStart "$ROOT"'
  run core 'coreStop "$ROOT"'
  [ "$status" -eq 0 ]
  [ "$(procs | wc -l)" -eq 0 ]
  [ ! -e "$ROOT/state/pid" ]
  run core 'coreRunning "$ROOT"'
  [ "$status" -eq 1 ]
}

@test "without systemd: stop waits for a binary that takes time to stop" {
  FAKEBIN_STOP_DELAY=2s core 'coreStart "$ROOT"'
  SECONDS=0
  run core 'coreStop "$ROOT"'
  [ "$SECONDS" -ge 2 ]
  [[ "$output" != *"SIGKILL"* ]]
  [ "$(procs | wc -l)" -eq 0 ]
}

@test "without systemd: a binary that doesn't stop in time is killed" {
  FAKEBIN_STOP_DELAY=60s core 'coreStart "$ROOT"'
  run core 'core_stop_wait=1; coreStop "$ROOT"'
  [[ "$output" == *"did not stop, sending SIGKILL"* ]]
  [ "$(procs | wc -l)" -eq 0 ]
}

@test "without systemd: pids from before a reboot don't count" {
  echo "$$" > "$ROOT/state/pid"
  run core 'coreRunning "$ROOT"'
  [ "$status" -eq 1 ]
  run core 'coreStart "$ROOT"'
  [ "$status" -eq 0 ]
  [ "$(procs | wc -l)" -eq 3 ]
  kill -0 "$$"
}

@test "without systemd: the binaries don't keep the core's lock" {
  run core 'lockAcquire "$ROOT/state/lock" ctrl.sh && coreStart "$ROOT"'
  [ "$status" -eq 0 ]
  [ "$(procs | wc -l)" -eq 3 ]
  run core 'lockHeld "$ROOT/state/lock"'
  [ "$status" -eq 1 ]
}

@test "with systemd: start starts the units and the mount" {
  with_systemd
  mkdir -p "$SECRETS"
  echo leftover > "$SECRETS/old-secret"
  run core 'coreStart "$ROOT"'
  [ "$status" -eq 0 ]
  for name in container-engine-wrapper host-manager core-manager; do
    [ "$(systemctl is-active "$CORE-$name.service")" = "active" ]
  done
  [ "$(systemctl is-active "mnt-$CORE-secrets.mount")" = "active" ]
  [ "$(findmnt -n -o FSTYPE "$SECRETS")" = "tmpfs" ]
  run core 'coreRunning "$ROOT"'
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT/state/pid" ]
}

@test "with systemd: stop stops the units, the mount stays" {
  with_systemd
  core 'coreStart "$ROOT"'
  run core 'coreStop "$ROOT"'
  [ "$status" -eq 0 ]
  [ "$(systemctl is-active "$CORE-core-manager.service")" = "inactive" ]
  [ "$(systemctl is-active "mnt-$CORE-secrets.mount")" = "active" ]
  run core 'coreRunning "$ROOT"'
  [ "$status" -eq 1 ]
}
