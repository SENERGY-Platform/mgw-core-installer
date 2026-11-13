#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# update.sh on the test VM: a core installed from a test release v0.40.0 (build_release.sh), updated
# against test releases served by the GitHub mock. The tests run in order.

load ../unit/helpers
load github

# Subnets and ports: each file has ranges of its own, so files can run in parallel (tests/vm/run.sh
# -j): core and gateway 10.<n>.0.0 and 10.<n>.1.0, module 10.<n+120>.0.0/16, with n in steps of ten
# per file (setup 20, uninstall 35, ctrl 45, update 55, update_failures 65, recover 75, version 85,
# restore 95, migration 105, migration_success 115, migration_nosystemd 125, migration_interrupted
# 10, update_archive 15);
# gateway ports per file in thousands from 20000. Only 10.x: docker uses 172.17.0.0/16 and up.

setup_file() {
  export REPO="$BATS_TEST_DIRNAME/../.."
  export MGW_TEST_RELEASES="$BATS_FILE_TMPDIR/releases"
  startGithubMock
  export DIR="/var/tmp/mgwt-update-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  export U="u$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  export ROOT="$DIR/$U"
  "$REPO/.github/build_release.sh" v0.40.0 "$MGW_TEST_RELEASES"
  mkdir -p "$BATS_FILE_TMPDIR/v0.40.0"
  tar -xzf "$MGW_TEST_RELEASES/mgw_core_installer_v0.40.0.tar.gz" -C "$BATS_FILE_TMPDIR/v0.40.0"
  local n=$((RANDOM % 8 + 55))
  printf '%s\n' "install_dir=$DIR" "core_id=$U" "gateway_port=$((23000 + RANDOM % 1000))" "subnet_core=10.$n.0.0" \
    "subnet_gateway=10.$n.1.0" "subnet_module=10.$((n + 120)).0.0" autostart=true start_core=true \
    logrotate=false cron=false advertise=false > "$BATS_FILE_TMPDIR/u.conf"
  "$BATS_FILE_TMPDIR/v0.40.0/setup.sh" -c "$BATS_FILE_TMPDIR/u.conf" > "$BATS_FILE_TMPDIR/u.log" 2>&1
}

teardown_file() {
  stopGithubMock
  if [ -d "$ROOT/state" ]; then
    rm -f "$ROOT/state/images"
    "$ROOT/current/uninstall.sh" -y > /dev/null 2>&1 || true
  fi
  rm -rf "$DIR" "/tmp/mgw_$U"
}

check() {
  grep -x "$1" "$ROOT/state/check"
}

@test "the core is installed from the test release" {
  cat "$BATS_FILE_TMPDIR/u.log" | tail -3
  grep -qx result=success "$ROOT/state/install"
  [ "$(cat "$ROOT/current/assets/version")" = "v0.40.0" ]
  [ "$(readlink "$ROOT/current")" = "v0_40_0" ]
  (cd "$ROOT/current/assets" && sha256sum -c --quiet checksums)
}

@test "nothing newer: up to date" {
  run "$ROOT/current/update.sh" -a
  echo "$output"
  [ "$status" -eq 0 ]
  check check_result=up_to_date
  [ ! -e "/tmp/mgw_$U" ]
}

@test "a beta isn't taken without allow_beta" {
  "$REPO/.github/build_release.sh" v0.41.0-beta1 "$MGW_TEST_RELEASES"
  run "$ROOT/current/update.sh" -a
  [ "$status" -eq 0 ]
  check check_result=up_to_date
  rm "$MGW_TEST_RELEASES/mgw_core_installer_v0.41.0-beta1.tar.gz"
}

@test "the retry limit: automatic runs skip a version that failed too often" {
  "$REPO/.github/build_release.sh" v0.41.0 "$MGW_TEST_RELEASES"
  printf '%s\n' version=v0_41_0 failures=3 > "$ROOT/state/attempts"
  run "$ROOT/current/update.sh" -a
  echo "$output"
  [ "$status" -eq 0 ]
  check check_result=skipped
  check "check_step=v0.41.0 failed 3 times"
  [ ! -e "$ROOT/v0_41_0_tmp" ]
  rm "$ROOT/state/attempts"
}

@test "a held lock refuses the run and records nothing" {
  cp "$ROOT/state/check" "$BATS_TEST_TMPDIR/check.before"
  printf '%s\n' holder=ctrl.sh pid=1 since=x > "$ROOT/state/lock"
  exec 7<> "$ROOT/state/lock"
  flock 7
  run "$ROOT/current/update.sh" -a
  exec 7>&-
  [ "$status" -eq 1 ]
  [[ "$output" == *"locked by ctrl.sh"* ]]
  cmp "$ROOT/state/check" "$BATS_TEST_TMPDIR/check.before"
}

@test "automatic runs don't update a dev version" {
  cp "$ROOT/current/assets/version" "$BATS_TEST_TMPDIR/version"
  echo dev-1762650000 > "$ROOT/current/assets/version"
  run "$ROOT/current/update.sh" -a
  cp "$BATS_TEST_TMPDIR/version" "$ROOT/current/assets/version"
  [ "$status" -eq 0 ]
  check check_result=skipped
  [[ "$output" == *"automatic runs don't update it"* ]]
}

@test "the old installer's hand-over is recognised" {
  mkdir -p "$BATS_TEST_TMPDIR/old"
  touch "$BATS_TEST_TMPDIR/old/.settings"
  # handed to migration.sh, which refuses this dummy before changing anything (tests/vm/migration*.bats)
  run "$REPO/assets/scripts/update.sh" -a "-path=$BATS_TEST_TMPDIR/old"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not migrating: cannot read $BATS_TEST_TMPDIR/old/.version"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/old/state" ]
  run "$REPO/assets/scripts/update.sh" -a "-path=$BATS_TEST_TMPDIR"
  [[ "$output" == *"is neither a core root (<install dir>/<core id>) nor an installation of the old installer"* ]]
}

# waits up to 5 minutes until $1 long-running containers of the project $2 run
waitForRunning() {
  local i=0 n
  while [ $i -lt 60 ]; do
    n="$(docker ps --filter "label=com.docker.compose.project=$2" --filter status=running --format '{{.Label "core_srv_oneshot"}}' | grep -c '^$' || true)"
    [ "$n" -eq "$1" ] && return 0
    sleep 5
    i=$((i + 1))
  done
  docker ps -a --filter "label=mgw_cid=$U" --format '{{.Names}} {{.Status}}'
  return 1
}

@test "an update of a running core: switched, started, old version cleaned up" {
  waitForRunning 7 "mgw_${U}_v0_40_0"
  run "$ROOT/current/update.sh" -a
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(readlink "$ROOT/current")" = "v0_41_0" ]
  [ ! -e "$ROOT/v0_40_0" ] && [ ! -e "$ROOT/v0_41_0_tmp" ]
  # the record
  grep -qx result=success "$ROOT/state/update"
  grep -qx phase=done "$ROOT/state/update"
  grep -qx from_version=v0.40.0 "$ROOT/state/update" && grep -qx to_version=v0.41.0 "$ROOT/state/update"
  grep -qx writer=v0_41_0 "$ROOT/state/update" && grep -qx old_folder=v0_40_0 "$ROOT/state/update"
  grep -qx was_running=true "$ROOT/state/update"
  ! grep -q '^warning=' "$ROOT/state/update"
  grep -qx failures=0 "$ROOT/state/attempts"
  check check_result=update_available && check check_version=v0.41.0
  # the new version runs, the old containers are gone
  [ "$(systemctl show -p ExecStart --value "mgw_$U-core-manager.service" | grep -o "path=[^ ;]*")" = "path=$ROOT/current/bin/SENERGY-Platform/mgw-core-manager/bin" ]
  [ "$(systemctl is-active "mgw_$U-core-manager.service")" = "active" ]
  [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=mgw_${U}_v0_40_0")" ]
  waitForRunning 7 "mgw_${U}_v0_41_0"
  # the scripts' log: stage one and stage two, each with its own name
  grep -q " update\.sh\[[0-9]*\]: checking for a new release" "$ROOT/log/scripts.log"
  grep -q " update\.sh-stage2\[[0-9]*\]: updated to v0.41.0" "$ROOT/log/scripts.log"
  # the core-manager serves it
  grep -q '"path": "'"$ROOT"'/log/scripts.log"' "$ROOT/current/config/host-binaries/SENERGY-Platform/mgw-core-manager/log_hdl.json"
}

@test "an update of a stopped core: it stays stopped, unused images are removed" {
  "$ROOT/current/ctrl.sh" stop > /dev/null
  mkdir -p "$BATS_TEST_TMPDIR/overlay"
  sed 's/^NGINX_IMG=nginx:.*/NGINX_IMG=nginx:1.31.0-alpine/' "$REPO/assets/options" > "$BATS_TEST_TMPDIR/overlay/options"
  "$REPO/.github/build_release.sh" v0.42.0 "$MGW_TEST_RELEASES" "$BATS_TEST_TMPDIR/overlay"
  local old_nginx
  old_nginx="$(grep '^NGINX_IMG=' "$REPO/assets/options" | cut -d= -f2)"
  run "$ROOT/current/update.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(readlink "$ROOT/current")" = "v0_42_0" ]
  grep -qx was_running=false "$ROOT/state/update"
  [ "$(systemctl is-active "mgw_$U-core-manager.service")" = "inactive" ]
  waitForRunning 0 "mgw_${U}_v0_42_0"
  grep -qx nginx:1.31.0-alpine "$ROOT/state/images"
  # removed, unless a container of another core still uses it (test files running in parallel): then
  # docker refuses, and it stays listed for the next cleanup
  if [ -z "$(docker ps -aq --filter "ancestor=$old_nginx")" ]; then
    ! grep -qx "$old_nginx" "$ROOT/state/images"
    ! docker image inspect "$old_nginx" > /dev/null 2>&1
  else
    grep -qx "$old_nginx" "$ROOT/state/images"
  fi
}

@test "an unfinished install is recovered under the update's lock first" {
  # a minimal core of folders only: its install never recorded success
  local fake="$DIR/fake"
  mkdir -p "$fake/state"
  cp -a "$ROOT/$(readlink "$ROOT/current")" "$fake/v0_40_0"
  ln -s v0_40_0 "$fake/current"
  printf '%s\n' "core_id=fake" "core_name=mgw_fake" > "$fake/state/settings"
  printf '%s\n' result=running created=folder:. created=folder:v0_40_0 > "$fake/state/install"
  run "$fake/current/update.sh" -a
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unfinished install found"* ]]
  [[ "$output" == *"not updating"* ]]
  [ ! -e "$fake" ]
}
