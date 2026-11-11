#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# The recovery of interrupted updates (PLAN.md 14) on the test VM: one running core with autostart,
# updated against test releases and killed with MGW_TEST_KILL_AT at a phase (SIGKILL, no handling of
# its own, like a power loss), then recovered. The tests run in order.

load ../unit/helpers
load github

# Subnets and ports: each file has ranges of its own, so files can run in parallel (tests/vm/run.sh
# -j): core and gateway 10.<n>.0.0 and 10.<n>.1.0, module 10.<n+120>.0.0/16, with n in steps of ten
# per file (setup 20, uninstall 35, ctrl 45, update 55, update_failures 65, recover 75, version 85,
# restore 95, migration 105, migration_success 115, migration_nosystemd 125, migration_interrupted
# 10);
# gateway ports per file in thousands from 20000. Only 10.x: docker uses 172.17.0.0/16 and up.

setup_file() {
  export REPO="$BATS_TEST_DIRNAME/../.."
  export MGW_TEST_RELEASES="$BATS_FILE_TMPDIR/releases"
  startGithubMock
  export DIR="/var/tmp/mgwt-recover-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  export R="r$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  export ROOT="$DIR/$R"
  "$REPO/tests/vm/build_release.sh" v0.40.0 "$MGW_TEST_RELEASES"
  mkdir -p "$BATS_FILE_TMPDIR/v0.40.0"
  tar -xzf "$MGW_TEST_RELEASES/mgw_core_installer_v0.40.0.tar.gz" -C "$BATS_FILE_TMPDIR/v0.40.0"
  local n=$((RANDOM % 8 + 75))
  printf '%s\n' "install_dir=$DIR" "core_id=$R" "gateway_port=$((25000 + RANDOM % 1000))" "subnet_core=10.$n.0.0" \
    "subnet_gateway=10.$n.1.0" "subnet_module=10.$((n + 120)).0.0" autostart=true start_core=true \
    logrotate=false cron=false advertise=false > "$BATS_FILE_TMPDIR/r.conf"
  "$BATS_FILE_TMPDIR/v0.40.0/setup.sh" -c "$BATS_FILE_TMPDIR/r.conf" > "$BATS_FILE_TMPDIR/r.log" 2>&1
  "$REPO/tests/vm/build_release.sh" v0.41.0 "$MGW_TEST_RELEASES"
}

teardown_file() {
  stopGithubMock
  if [ -d "$ROOT/state" ]; then
    rm -f "$ROOT/state/images"
    "$ROOT/current/uninstall.sh" -y > /dev/null 2>&1 || "$REPO/assets/scripts/uninstall.sh" -path="$ROOT" -y > /dev/null 2>&1 || true
  fi
  rm -rf "$DIR" "/tmp/mgw_$R"
}

rec() {
  grep -x "$1" "$ROOT/state/update"
}

waitForRunning() {
  local i=0 n
  while [ $i -lt 60 ]; do
    n="$(docker ps --filter "label=com.docker.compose.project=mgw_${R}_$2" --filter status=running --format '{{.Label "core_srv_oneshot"}}' | grep -c '^$' || true)"
    [ "$n" -eq "$1" ] && return 0
    sleep 5
    i=$((i + 1))
  done
  docker ps -a --filter "label=mgw_cid=$R" --format '{{.Names}} {{.Status}}'
  return 1
}

# runs an update killed at the step $1 and checks it left a "running" record in the phase $2
killedAt() {
  run env MGW_TEST_KILL_AT="$1" "$ROOT/current/update.sh"
  echo "$output"
  rec result=running
  rec "phase=$2"
}

@test "the core runs v0.40.0" {
  grep -qx result=success "$ROOT/state/install"
  waitForRunning 7 v0_40_0
}

@test "killed in B, recovered by the recovery unit: handed over to the writer, the new version removed" {
  killedAt preparing preparing
  # the current version's recovery hands over to the writer, v0.41.0
  systemctl restart "mgw_$R-recover.service"
  journalctl -u "mgw_$R-recover.service" -n 30 --no-pager | grep -q "handing the recovery over to v0_41_0"
  rec result=failed && rec interrupted=true && rec rolled_back=false && rec phase=preparing
  rec "warning=interrupted, recovered by the boot recovery"
  [ ! -e "$ROOT/v0_41_0" ] && [ ! -e "$ROOT/v0_41_0_tmp" ]
  [ "$(readlink "$ROOT/current")" = "v0_40_0" ]
  waitForRunning 7 v0_40_0
}

@test "killed after the stop, recovered by the next update: rolled back and started, then updated" {
  killedAt stopped switching
  [ "$(systemctl is-active "mgw_$R-core-manager.service")" = "inactive" ]
  run "$ROOT/current/update.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"interrupted in phase switching"* ]] && [[ "$output" == *"rolling back to v0_40_0"* ]]
  rec result=success
  [ "$(readlink "$ROOT/current")" = "v0_41_0" ]
  waitForRunning 7 v0_41_0
}

@test "killed after the switch, recovered at boot: rolled back without starting units" {
  "$REPO/tests/vm/build_release.sh" v0.42.0 "$MGW_TEST_RELEASES"
  killedAt activated switching
  [ "$(readlink "$ROOT/current")" = "v0_42_0" ]
  run "$ROOT/current/assets/scripts/recover.sh" -boot
  echo "$output"
  [ "$status" -eq 0 ]
  rec result=failed && rec interrupted=true && rec rolled_back=true
  [ "$(readlink "$ROOT/current")" = "v0_41_0" ]
  [ ! -e "$ROOT/v0_42_0" ]
  # at boot the units start by themselves; here nothing started them
  [ "$(systemctl is-active "mgw_$R-core-manager.service")" = "inactive" ]
  grep -qx failures=1 "$ROOT/state/attempts"
  "$ROOT/current/ctrl.sh" start > /dev/null
  waitForRunning 7 v0_41_0
}

@test "killed while starting: past the point of no return, not rolled back" {
  killedAt starting starting
  run "$ROOT/current/assets/scripts/recover.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  rec result=failed && rec interrupted=true && rec rolled_back=false && rec phase=starting
  [ "$(readlink "$ROOT/current")" = "v0_42_0" ]
  [ -d "$ROOT/v0_41_0" ]
}

@test "the writer's folder missing: G9, the record taken over, ctrl.sh and update.sh refuse" {
  "$ROOT/current/ctrl.sh" stop > /dev/null
  rm -f "$ROOT/state/attempts"
  "$REPO/tests/vm/build_release.sh" v0.43.0 "$MGW_TEST_RELEASES"
  killedAt switching switching
  rm -rf "$ROOT/v0_43_0"
  run "$ROOT/current/assets/scripts/recover.sh"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the version folder v0_43_0 of the interrupted update is missing"* ]]
  rec result=failed && rec recovery_failed=true && rec interrupted=true
  rec "writer=$(readlink "$ROOT/current")"
  grep -qx writer=v0_43_0 "$ROOT/state/update.previous"
  grep -qx result=running "$ROOT/state/update.previous"
  run "$ROOT/current/ctrl.sh" start
  [ "$status" -eq 1 ]
  run "$ROOT/current/update.sh" -a
  [ "$status" -eq 1 ]
  [[ "$output" == *"restore.sh"* ]]
}

@test "the writer's folder damaged: G9" {
  # back to a clean state for this test
  rm -f "$ROOT/state/update" "$ROOT/state/update.previous"
  killedAt switching switching
  echo "# damaged" >> "$ROOT/v0_43_0/assets/scripts/lib/update.sh"
  run "$ROOT/current/assets/scripts/recover.sh"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is damaged (checksums)"* ]]
  rec recovery_failed=true
}
