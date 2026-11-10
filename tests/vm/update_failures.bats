#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# The update's error handling per phase (PLAN.md 13) on the test VM: one running core with autostart,
# updated against test releases, with failures injected through MGW_TEST_FAIL_AT. The tests run in
# order; each one that fails an update leaves the core on its previous version.

load ../unit/helpers
load github

# Subnets: only 10.x ranges, docker uses 172.17.0.0/16 and up for its own networks.

setup_file() {
  export REPO="$BATS_TEST_DIRNAME/../.."
  export MGW_TEST_RELEASES="$BATS_FILE_TMPDIR/releases"
  startGithubMock
  export DIR="/var/tmp/mgwt-fail-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  export F="f$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  export ROOT="$DIR/$F"
  "$REPO/tests/vm/build_release.sh" v0.40.0 "$MGW_TEST_RELEASES"
  mkdir -p "$BATS_FILE_TMPDIR/v0.40.0"
  tar -xzf "$MGW_TEST_RELEASES/mgw_core_installer_v0.40.0.tar.gz" -C "$BATS_FILE_TMPDIR/v0.40.0"
  local n=$((RANDOM % 90 + 20))
  printf '%s\n' "install_dir=$DIR" "core_id=$F" "gateway_port=$((20000 + RANDOM % 10000))" "subnet_core=10.$n.0.0" \
    "subnet_gateway=10.$n.1.0" "subnet_module=10.$((n + 120)).0.0" autostart=true start_core=true \
    logrotate=false cron=false advertise=false > "$BATS_FILE_TMPDIR/f.conf"
  "$BATS_FILE_TMPDIR/v0.40.0/setup.sh" -c "$BATS_FILE_TMPDIR/f.conf" > "$BATS_FILE_TMPDIR/f.log" 2>&1
  "$REPO/tests/vm/build_release.sh" v0.41.0 "$MGW_TEST_RELEASES"
}

teardown_file() {
  stopGithubMock
  if [ -d "$ROOT/state" ]; then
    rm -f "$ROOT/state/images"
    "$ROOT/current/uninstall.sh" -y > /dev/null 2>&1 || true
  fi
  rm -rf "$DIR" "/tmp/mgw_$F"
}

rec() {
  grep -x "$1" "$ROOT/state/update"
}

# waits up to 5 minutes until $1 long-running containers of the version folder $2 run
waitForRunning() {
  local i=0 n
  while [ $i -lt 60 ]; do
    n="$(docker ps --filter "label=com.docker.compose.project=mgw_${F}_$2" --filter status=running --format '{{.Label "core_srv_oneshot"}}' | grep -c '^$' || true)"
    [ "$n" -eq "$1" ] && return 0
    sleep 5
    i=$((i + 1))
  done
  docker ps -a --filter "label=mgw_cid=$F" --format '{{.Names}} {{.Status}}'
  return 1
}

# the core is back on the version folder $1 and runs: units active, its containers up
backOn() {
  [ "$(readlink "$ROOT/current")" = "$1" ]
  [ "$(systemctl is-active "mgw_$F-core-manager.service")" = "active" ]
  waitForRunning 7 "$1"
}

@test "the core runs v0.40.0" {
  grep -qx result=success "$ROOT/state/install"
  waitForRunning 7 v0_40_0
}

@test "B: a failure in the preparation leaves the core untouched, doesn't count" {
  run env MGW_TEST_FAIL_AT=prepare "$ROOT/current/update.sh" -a
  echo "$output"
  [ "$status" -eq 1 ]
  rec result=failed && rec rolled_back=false && rec phase=preparing
  [ ! -e "$ROOT/v0_41_0" ] && [ ! -e "$ROOT/v0_41_0_tmp" ]
  [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=mgw_${F}_v0_41_0")" ]
  [ ! -e "$ROOT/state/attempts" ] || grep -qx failures=0 "$ROOT/state/attempts"
  grep -q "check_result=failed" "$ROOT/state/check"
  backOn v0_40_0
}

@test "C: a failure while stopping is rolled back and counted" {
  run env MGW_TEST_FAIL_AT=stop "$ROOT/current/update.sh" -a
  echo "$output"
  [ "$status" -eq 1 ]
  rec result=failed && rec rolled_back=true && rec phase=switching
  grep -qx failures=1 "$ROOT/state/attempts"
  [ ! -e "$ROOT/v0_41_0" ]
  [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=mgw_${F}_v0_41_0")" ]
  backOn v0_40_0
}

@test "C: a failure after current was switched is rolled back" {
  run env MGW_TEST_FAIL_AT=activate "$ROOT/current/update.sh"
  echo "$output"
  [ "$status" -eq 1 ]
  rec result=failed && rec rolled_back=true
  [ ! -e "$ROOT/v0_41_0" ]
  backOn v0_40_0
}

@test "S8: a start failing before any binary runs is still rolled back" {
  run env MGW_TEST_FAIL_AT=start "$ROOT/current/update.sh"
  echo "$output"
  [ "$status" -eq 1 ]
  rec result=failed && rec rolled_back=true && rec phase=starting
  [[ "$output" == *"no host binary started"* ]]
  backOn v0_40_0
}

@test "S2: a stopped core whose success can't be recorded is rolled back" {
  "$ROOT/current/ctrl.sh" stop > /dev/null
  run env MGW_TEST_FAIL_AT=success "$ROOT/current/update.sh"
  echo "$output"
  [ "$status" -eq 1 ]
  rec result=failed && rec rolled_back=true
  [ "$(readlink "$ROOT/current")" = "v0_40_0" ]
  [ "$(systemctl is-active "mgw_$F-core-manager.service")" = "inactive" ]
  "$ROOT/current/ctrl.sh" start > /dev/null
  waitForRunning 7 v0_40_0
}

@test "E: a failed cleanup is a warning, the update succeeded" {
  run env MGW_TEST_FAIL_AT=cleanup "$ROOT/current/update.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  rec result=success
  rec "warning=the cleanup failed (test)"
  backOn v0_41_0
}

@test "D: a failure after the start isn't rolled back, the old version is kept" {
  "$REPO/tests/vm/build_release.sh" v0.42.0 "$MGW_TEST_RELEASES"
  run env MGW_TEST_FAIL_AT=started "$ROOT/current/update.sh" -a
  echo "$output"
  [ "$status" -eq 1 ]
  rec result=failed && rec rolled_back=false && rec phase=starting
  grep -qx version=v0_42_0 "$ROOT/state/attempts" && grep -qx failures=1 "$ROOT/state/attempts"
  [ "$(readlink "$ROOT/current")" = "v0_42_0" ]
  [ -d "$ROOT/v0_41_0" ]
  [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=mgw_${F}_v0_41_0")" ]
  waitForRunning 7 v0_42_0
}

@test "the next successful update removes the leftovers of the failed ones" {
  "$REPO/tests/vm/build_release.sh" v0.43.0 "$MGW_TEST_RELEASES"
  run "$ROOT/current/update.sh" -a
  echo "$output"
  [ "$status" -eq 0 ]
  rec result=success
  ! rec "warning=.*"
  [ "$(ls -d "$ROOT"/v* | xargs -n1 basename)" = "v0_43_0" ]
  [ -z "$(docker ps -aq --filter "label=mgw_cid=$F" | xargs -r docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' | grep -v "^mgw_${F}_v0_43_0$")" ]
  backOn v0_43_0
}

@test "SIGTERM during the preparation gets B's handling" {
  "$REPO/tests/vm/build_release.sh" v0.44.0 "$MGW_TEST_RELEASES"
  setsid "$ROOT/current/update.sh" > "$BATS_TEST_TMPDIR/term.log" 2>&1 &
  local pid=$! i=0
  until grep -qx phase=preparing "$ROOT/state/update" 2> /dev/null && grep -qx to_version=v0.44.0 "$ROOT/state/update" 2> /dev/null; do
    sleep 0.2; i=$((i + 1)); [ $i -lt 300 ]
  done
  sleep 1
  kill -TERM -- "-$pid"
  wait "$pid" || true
  cat "$BATS_TEST_TMPDIR/term.log"
  rec result=failed && rec rolled_back=false && rec step=interrupted
  [ ! -e "$ROOT/v0_44_0" ] && [ ! -e "$ROOT/v0_44_0_tmp" ]
  backOn v0_43_0
}

@test "G9: a failing rollback stops everything and points to restore.sh" {
  run env MGW_TEST_FAIL_AT="stop rollback" "$ROOT/current/update.sh"
  echo "$output"
  [ "$status" -eq 1 ]
  rec result=failed && rec rolled_back=false && rec recovery_failed=true
  [[ "$output" == *"restore.sh"* ]]
  run "$ROOT/current/ctrl.sh" start
  [ "$status" -eq 1 ]
  [[ "$output" == *"the recovery of an interrupted update failed"* ]]
}
