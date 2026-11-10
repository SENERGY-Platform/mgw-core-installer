#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# ctrl.sh's state check and status report against records in a temporary core root. The commands
# themselves are tested on the VM (tests/vm/ctrl.bats).

load helpers

setup() {
  export ROOT="$BATS_TEST_TMPDIR/core"
  mkdir -p "$ROOT/state" "$ROOT/v1_3_0/assets"
  ln -s v1_3_0 "$ROOT/current"
  echo v1.3.0 > "$ROOT/v1_3_0/assets/version"
  printf '%s\n' 'core_id=' 'core_name=' 'autostart=true' 'secrets_size=100M' > "$BATS_TEST_TMPDIR/defaults"
  printf '%s\n' 'core_id=abc' 'core_name=mgw_abc' > "$ROOT/state/settings"
  printf '%s\n' 'result=success' > "$ROOT/state/install"
}

ctrl() {
  dsh 'settingsLoad "$BATS_TEST_TMPDIR/defaults" "$ROOT/state/settings" || exit 9; '"$1" file settings state lock ctrl
}

@test "a healthy core needs no repair" {
  printf '%s\n' result=success from_version=v1.2.0 to_version=v1.3.0 > "$ROOT/state/update"
  run ctrl 'ctrlProblem "$ROOT"'
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
}

@test "no records at all need no repair" {
  rm "$ROOT/state/install"
  run ctrl 'ctrlProblem "$ROOT"'
  [ "$status" -eq 1 ]
}

@test "an unfinished install needs repair" {
  printf '%s\n' result=running > "$ROOT/state/install"
  run ctrl 'ctrlProblem "$ROOT"'
  [ "$status" -eq 0 ]
  [ "$output" = "the install of this core didn't finish (result 'running')" ]
}

@test "an interrupted update needs repair" {
  printf '%s\n' result=running from_version=v1.2.0 to_version=v1.3.0 phase=switching > "$ROOT/state/update"
  run ctrl 'ctrlProblem "$ROOT"'
  [ "$status" -eq 0 ]
  [ "$output" = "an update was interrupted (from v1.2.0 to v1.3.0, phase switching)" ]
}

@test "a failed recovery (G9) needs repair" {
  printf '%s\n' result=failed interrupted=true recovery_failed=true > "$ROOT/state/update"
  run ctrl 'ctrlProblem "$ROOT"'
  [ "$status" -eq 0 ]
  [ "$output" = "the recovery of an interrupted update failed" ]
}

@test "an unreadable update record needs repair" {
  head -c 70000 /dev/zero | tr '\0' a > "$ROOT/state/update"
  run ctrl 'ctrlProblem "$ROOT"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"can't be read"* ]]
}

@test "a failed update that was rolled back needs no repair" {
  printf '%s\n' result=failed rolled_back=true > "$ROOT/state/update"
  run ctrl 'ctrlProblem "$ROOT"'
  [ "$status" -eq 1 ]
}

@test "status reports the core, its last update and check" {
  printf '%s\n' result=failed kind=update from_version=v1.2.0 to_version=v1.3.0 started=s finished=f rolled_back=true \
    step="pulling images" warning="avahi reload failed" > "$ROOT/state/update"
  printf '%s\n' check_result=update_available check_time=t check_version=v1.4.0 > "$ROOT/state/check"
  run ctrl 'ctrlReport "$ROOT" running "9 of 9 running" 100M'
  [ "$status" -eq 0 ]
  [[ "$output" == *"core:        mgw_abc (core id abc)"* ]]
  [[ "$output" == *"version:     v1.3.0 (v1_3_0)"* ]]
  [[ "$output" == *"autostart:   true"* ]]
  [[ "$output" == *"secrets:     100M mounted, 100M configured"* ]]
  [[ "$output" == *"last update: failed (update v1.2.0 -> v1.3.0, started s, finished f)"* ]]
  [[ "$output" == *"rolled back to the previous version"* ]]
  [[ "$output" == *"step: pulling images"* ]]
  [[ "$output" == *"warning: avahi reload failed"* ]]
  [[ "$output" == *"last check:  update_available at t (found v1.4.0)"* ]]
  [[ "$output" == *"lock:        not locked"* ]]
  [[ "$output" != *"needs repair"* ]]
}

@test "status points to restore.sh if the core needs repair and nobody holds the lock" {
  printf '%s\n' result=running > "$ROOT/state/update"
  run ctrl 'ctrlReport "$ROOT" stopped "0 of 7 running" not'
  [[ "$output" == *"the core needs repair: an update was interrupted"* ]]
  [[ "$output" == *"run $ROOT/current/restore.sh"* ]]
}

@test "status doesn't call a running update interrupted while its lock is held" {
  printf '%s\n' result=running > "$ROOT/state/update"
  printf '%s\n' holder=update pid=1 since=x > "$ROOT/state/lock"
  exec 7<> "$ROOT/state/lock"
  flock 7
  run ctrl 'ctrlReport "$ROOT" running "9 of 9 running" 100M'
  exec 7>&-
  [[ "$output" == *"lock:        locked by update"* ]]
  [[ "$output" == *"last update: running"* ]]
  [[ "$output" != *"needs repair"* ]]
}
