#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# restore.sh on the test VM (PLAN.md 10b, m6-restore.md): one running core with autostart, installed
# from a test release v0.40.0, broken in various ways and restored. The tests run in order.

load ../unit/helpers
load github

# Subnets and ports: each file has ranges of its own, so files can run in parallel (tests/vm/run.sh
# -j); restore uses n from 95 and ports from 26000 (see the other files).

setup_file() {
  export REPO="$BATS_TEST_DIRNAME/../.."
  export MGW_TEST_RELEASES="$BATS_FILE_TMPDIR/releases"
  startGithubMock
  export DIR="/var/tmp/mgwt-restore-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  export S="s$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  export ROOT="$DIR/$S"
  local v
  for v in v0.40.0 v0.41.0; do
    "$REPO/.github/build_release.sh" "$v" "$MGW_TEST_RELEASES"
    mkdir -p "$BATS_FILE_TMPDIR/$v"
    tar -xzf "$MGW_TEST_RELEASES/mgw_core_installer_$v.tar.gz" -C "$BATS_FILE_TMPDIR/$v"
  done
  export A40="$BATS_FILE_TMPDIR/v0.40.0" A41="$BATS_FILE_TMPDIR/v0.41.0"
  # the releases the updates find: only v0.40.0 until a test adds v0.41.0
  rm "$MGW_TEST_RELEASES/mgw_core_installer_v0.41.0.tar.gz"
  local n=$((RANDOM % 3 + 95))
  printf '%s\n' "install_dir=$DIR" "core_id=$S" "gateway_port=$((26000 + RANDOM % 1000))" "subnet_core=10.$n.0.0" \
    "subnet_gateway=10.$n.1.0" "subnet_module=10.$((n + 120)).0.0" autostart=true start_core=true \
    logrotate=false cron=false advertise=false > "$BATS_FILE_TMPDIR/s.conf"
  "$A40/setup.sh" -c "$BATS_FILE_TMPDIR/s.conf" > "$BATS_FILE_TMPDIR/s.log" 2>&1
}

teardown_file() {
  stopGithubMock
  rm -f "$ROOT/state/images"
  "$REPO/assets/scripts/uninstall.sh" -path="$ROOT" -y > /dev/null 2>&1 || true
  rm -rf "$DIR" "/tmp/mgw_$S"
}

waitForRunning() {
  local i=0 n
  while [ $i -lt 60 ]; do
    n="$(docker ps --filter "label=com.docker.compose.project=mgw_${S}_$2" --filter status=running --format '{{.Label "core_srv_oneshot"}}' | grep -c '^$' || true)"
    [ "$n" -eq "$1" ] && return 0
    sleep 5
    i=$((i + 1))
  done
  docker ps -a --filter "label=mgw_cid=$S" --format '{{.Names}} {{.Status}}'
  return 1
}

restored() {
  grep -qx result=success "$ROOT/state/restore"
  grep -qx "version=$1" "$ROOT/state/restore"
  [ "$(readlink "$ROOT/current")" = "$2" ]
  [ ! -e "$ROOT/.restore" ]
  waitForRunning 7 "$2"
}

@test "the core runs v0.40.0" {
  grep -qx result=success "$ROOT/state/install"
  waitForRunning 7 v0_40_0
}

@test "a healthy core restored from the install directory: rebuilt, running again" {
  local before
  before="$(docker ps -aq --filter "label=mgw_cid=$S" | sort)"
  run "$ROOT/current/restore.sh" -y
  echo "$output"
  [ "$status" -eq 0 ]
  restored v0.40.0 v0_40_0
  [ -z "$(comm -12 <(echo "$before") <(docker ps -aq --filter "label=mgw_cid=$S" | sort))" ]
  [ ! -e "$ROOT/state/update" ]
}

@test "a deleted version folder, restored from the archive" {
  rm -rf "$ROOT/v0_40_0"
  run "$A40/restore.sh" -path="$ROOT" -y
  echo "$output"
  [ "$status" -eq 0 ]
  restored v0.40.0 v0_40_0
}

@test "a damaged current, restored from the install directory" {
  rm -rf "$ROOT/v0_40_0/config"
  run "$ROOT/current/restore.sh" -y
  echo "$output"
  [ "$status" -eq 0 ]
  restored v0.40.0 v0_40_0
  [ -f "$ROOT/v0_40_0/config/container/docker-compose.yml" ]
}

@test "an interrupted update is recovered, nothing rebuilt" {
  "$REPO/.github/build_release.sh" v0.41.0 "$MGW_TEST_RELEASES"
  MGW_TEST_KILL_AT=preparing "$ROOT/current/update.sh" > /dev/null 2>&1 || true
  grep -qx result=running "$ROOT/state/update"
  cp "$ROOT/state/restore" "$BATS_TEST_TMPDIR/restore.before"
  run "$ROOT/current/restore.sh" -y
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"recovered, nothing to rebuild"* ]]
  cmp "$ROOT/state/restore" "$BATS_TEST_TMPDIR/restore.before"
  grep -qx result=failed "$ROOT/state/update" && grep -qx interrupted=true "$ROOT/state/update"
  [ ! -e "$ROOT/v0_41_0" ] && [ ! -e "$ROOT/v0_41_0_tmp" ]
  waitForRunning 7 v0_40_0
}

@test "G9: rebuilt, the update record keeps its cause and is marked restored" {
  run env MGW_TEST_FAIL_AT="stop rollback" "$ROOT/current/update.sh"
  grep -qx recovery_failed=true "$ROOT/state/update"
  run "$ROOT/current/restore.sh" -y
  echo "$output"
  [ "$status" -eq 0 ]
  restored v0.40.0 v0_40_0
  grep -qx result=failed "$ROOT/state/update" && grep -qx restored=true "$ROOT/state/update"
  ! grep -qx recovery_failed=true "$ROOT/state/update"
  grep -qx to_version=v0.41.0 "$ROOT/state/update" && grep -q "^step=.*the rollback failed" "$ROOT/state/update"
  grep -qx recovery_failed=true "$ROOT/state/update.previous"
  run "$ROOT/current/ctrl.sh" restart
  [ "$status" -eq 0 ]
}

@test "after the restore, updates work again" {
  rm -f "$ROOT/state/attempts"
  run "$ROOT/current/update.sh" -a
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qx result=success "$ROOT/state/update"
  [ "$(readlink "$ROOT/current")" = "v0_41_0" ]
  waitForRunning 7 v0_41_0
}

@test "an older version needs -downgrade" {
  run "$A40/restore.sh" -path="$ROOT" -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"v0.40.0 is older than v0.41.0"* ]] && [[ "$output" == *"add -downgrade"* ]]
  [ "$(readlink "$ROOT/current")" = "v0_41_0" ]
  run "$A40/restore.sh" -path="$ROOT" -y -downgrade
  echo "$output"
  [ "$status" -eq 0 ]
  restored v0.40.0 v0_40_0
  [ ! -e "$ROOT/v0_41_0" ]
}

@test "a missing volume is named, recreated empty and recorded" {
  "$ROOT/current/ctrl.sh" stop > /dev/null
  docker ps -aq --filter "label=mgw_cid=$S" | xargs -r docker rm -f > /dev/null
  docker volume rm "mgw_${S}_kratos-home" > /dev/null
  run "$ROOT/current/restore.sh" -y
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"the volume mgw_${S}_kratos-home is missing: its data is lost, it is created empty"* ]]
  grep -qx "warning=the volume mgw_${S}_kratos-home was missing and was created empty" "$ROOT/state/restore"
  docker volume inspect "mgw_${S}_kratos-home" > /dev/null
  # the core was stopped on purpose: it stays stopped
  [ "$(systemctl is-active "mgw_$S-core-manager.service")" = "inactive" ]
  "$ROOT/current/ctrl.sh" start > /dev/null
  waitForRunning 7 v0_40_0
}

@test "a lost core root, restored with a copy of state/settings" {
  cp "$ROOT/state/settings" "$BATS_FILE_TMPDIR/settings.backup"
  "$ROOT/current/ctrl.sh" stop > /dev/null
  rm -rf "$ROOT"
  run "$A40/restore.sh" -path="$ROOT" -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"no state/settings"* ]] && [[ "$output" == *"-s=<file>"* ]]
  run "$A40/restore.sh" -path="$ROOT" -s="$BATS_FILE_TMPDIR/settings.backup" -y
  echo "$output"
  [ "$status" -eq 0 ]
  cmp "$ROOT/state/settings" "$BATS_FILE_TMPDIR/settings.backup"
  [ "$(stat -c %a "$ROOT/state/settings")" = "600" ]
  [ ! -e "$ROOT/state/install" ]
  # no target state any more: autostart decides, it starts
  restored v0.40.0 v0_40_0
}

@test "a failed restore: ctrl.sh and the recovery refuse, the copy in .restore repeats it" {
  run env MGW_TEST_FAIL_AT=restore "$ROOT/current/restore.sh" -y
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"run $ROOT/.restore/assets/scripts/restore.sh -path=$ROOT again"* ]]
  grep -qx result=failed "$ROOT/state/restore"
  [ ! -e "$ROOT/current" ]
  run "$ROOT/v0_40_0/assets/scripts/recover.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a restore didn't finish"* ]]
  run "$ROOT/.restore/assets/scripts/restore.sh" -path="$ROOT" -y
  echo "$output"
  [ "$status" -eq 0 ]
  restored v0.40.0 v0_40_0
}
