#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# ctrl.sh's state check and status report against records in a temporary core root. The commands
# themselves are tested on the VM (tests/vm/ctrl.bats).

load helpers

setup() {
  export SHIPPED="$BATS_TEST_DIRNAME/../../assets/settings.defaults"
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

ctrl_shipped() {
  dsh 'settingsLoad "$SHIPPED" "" || exit 9; '"$1" file settings state lock setup ctrl
}

@test "settings: what changing each shipped setting involves" {
  run ctrl_shipped 'for k in $settings_keys; do echo "$k $(ctrlSettingKind "$k")"; done'
  [ "$status" -eq 0 ]
  for line in "allow_beta none" "update_retry_limit none" "kratos_log_level recreate" "module_manager_dep_startup_delay recreate" \
    "module_manager_http_access_log recreate" "gateway_port port" "logrotate integration" "cron integration" "advertise integration" \
    "secrets_size secrets" "autostart autostart" "core_id refused" "core_name refused" "stack_name refused" "subnet_core refused" \
    "core_db_pw refused" "core_usr refused" "host_dir_repository_path refused"; do
    [[ "$output" == *"$line"* ]] || { echo "missing: $line"; false; }
  done
  # every shipped setting has a rule
  [[ "$output" != *" unknown"* ]]
  run ctrl_shipped 'ctrlSettingKind no_such_setting'
  [ "$output" = "unknown" ]
}

@test "settings: only floating settings can be reset" {
  run ctrl_shipped 'ctrlResettable allow_beta && ctrlResettable kratos_log_level && ! ctrlResettable gateway_port && ! ctrlResettable autostart && ! ctrlResettable core_id'
  [ "$status" -eq 0 ]
}

@test "settings: refused ones say why" {
  run ctrl_shipped 'ctrlRefusedReason core_id; ctrlRefusedReason subnet_module; ctrlRefusedReason core_db_pw'
  [[ "${lines[0]}" == *"identity"* ]] && [[ "${lines[1]}" == *"docker networks"* ]] && [[ "${lines[2]}" == *"credentials"* ]]
}

@test "settings: the list shows the changeable ones, marks set values, explains itself" {
  { dsh 'settingsHeader' settings; printf '%s\n' 'core_id=abc' 'core_db_pw=secret123' 'allow_beta=true'; } > "$BATS_TEST_TMPDIR/settings"
  run dsh 'settingsLoad "$SHIPPED" "$BATS_TEST_TMPDIR/settings"; ctrlSettingsList' file settings state lock ctrl
  [[ "$output" == *"allow_beta=true (set)"$'\n'* ]]
  [[ "$output" == *"gateway_port=8080"$'\n'* ]]
  # the fixed ones only with -a
  [[ "$output" != *"core_id="* ]] && [[ "$output" != *"core_db_pw="* ]] && [[ "$output" != *"subnet_core="* ]]
  [[ "$output" == *"(set): set for this core; the others are the version's defaults"* ]]
  [[ "$output" == *"the core's identity, credentials and subnets are fixed: ctrl.sh settings list -a"* ]]
}

@test "settings: with -a also the fixed ones, marked, passwords hidden" {
  printf '%s\n' 'core_id=abc' 'core_db_pw=secret123' 'allow_beta=true' > "$BATS_TEST_TMPDIR/settings"
  run dsh 'settingsLoad "$SHIPPED" "$BATS_TEST_TMPDIR/settings"; ctrlSettingsList all' file settings state lock ctrl
  [[ "$output" == *"core_id=abc (set) fixed"$'\n'* ]]
  [[ "$output" == *"core_db_pw=(hidden) (set) fixed"$'\n'* ]]
  [[ "$output" == *"subnet_core=10.0.0.0 fixed"$'\n'* ]]
  [[ "$output" == *"allow_beta=true (set)"$'\n'* ]]
  [[ "$output" == *"fixed: the core's identity, credentials and subnets, can't be changed"* ]]
  [[ "$output" != *"secret123"* ]]
}

@test "settings: validation of the changeable values" {
  for kv in update_retry_limit=3 secrets_size=100M secrets_size=512k secrets_size=1G secrets_size=1048576 kratos_log_level=debug \
    module_manager_dep_startup_delay=20s module_manager_aux_dep_startup_delay=5m module_manager_http_access_log=true; do
    run ctrl_shipped 'setupValidate "'"${kv%%=*}"'" "'"${kv#*=}"'"'
    [ "$status" -eq 0 ] || { echo "refused $kv: $output"; false; }
  done
  for kv in update_retry_limit=0 update_retry_limit=x secrets_size=M secrets_size=10Mb secrets_size=0M secrets_size=-1M \
    kratos_log_level=Debug kratos_log_level= "kratos_log_level=warn ing" 'kratos_log_level=$x' module_manager_dep_startup_delay=20 \
    module_manager_dep_startup_delay=s module_manager_dep_startup_delay=1.5s module_manager_http_access_log=yes; do
    run ctrl_shipped 'setupValidate "'"${kv%%=*}"'" "'"${kv#*=}"'"'
    [ "$status" -eq 1 ] || { echo "accepted $kv"; false; }
  done
}

@test "a restore that didn't finish needs repair" {
  printf '%s\n' result=running > "$ROOT/state/restore"
  run ctrl 'ctrlProblem "$ROOT"'
  [ "$status" -eq 0 ]
  [ "$output" = "a restore didn't finish (result 'running')" ]
  printf '%s\n' result=failed > "$ROOT/state/restore"
  run ctrl 'ctrlProblem "$ROOT"'
  [ "$status" -eq 0 ]
  printf '%s\n' result=success > "$ROOT/state/restore"
  run ctrl 'ctrlProblem "$ROOT"'
  [ "$status" -eq 1 ]
}

@test "the restore.sh to run: current's, or the copy a failed restore left" {
  mkdir -p "$ROOT/v1_3_0" && ln -s assets/scripts/restore.sh "$ROOT/v1_3_0/restore.sh"
  run ctrl 'ctrlRestoreCommand "$ROOT"'
  [ "$output" = "$ROOT/current/restore.sh" ]
  rm "$ROOT/current"
  mkdir -p "$ROOT/.restore/assets/scripts" && printf '#!/bin/sh\n' > "$ROOT/.restore/assets/scripts/restore.sh" && chmod +x "$ROOT/.restore/assets/scripts/restore.sh"
  run ctrl 'ctrlRestoreCommand "$ROOT"'
  [ "$output" = "$ROOT/.restore/assets/scripts/restore.sh -path=$ROOT" ]
}
