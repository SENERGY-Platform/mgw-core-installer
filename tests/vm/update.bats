#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# update.sh on the test VM: a core installed from a test release v0.40.0 (build_release.sh), updated
# against test releases served by the GitHub mock. The tests run in order.

load ../unit/helpers
load github

# Subnets: only 10.x ranges, docker uses 172.17.0.0/16 and up for its own networks.

setup_file() {
  export REPO="$BATS_TEST_DIRNAME/../.."
  export MGW_TEST_RELEASES="$BATS_FILE_TMPDIR/releases"
  startGithubMock
  export DIR="/var/tmp/mgwt-update-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  export U="u$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  export ROOT="$DIR/$U"
  "$REPO/tests/vm/build_release.sh" v0.40.0 "$MGW_TEST_RELEASES"
  mkdir -p "$BATS_FILE_TMPDIR/v0.40.0"
  tar -xzf "$MGW_TEST_RELEASES/mgw_core_installer_v0.40.0.tar.gz" -C "$BATS_FILE_TMPDIR/v0.40.0"
  local n=$((RANDOM % 90 + 20))
  printf '%s\n' "install_dir=$DIR" "core_id=$U" "gateway_port=$((20000 + RANDOM % 10000))" "subnet_core=10.$n.0.0" \
    "subnet_gateway=10.$n.1.0" "subnet_module=10.$((n + 120)).0.0" autostart=false start_core=false \
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

@test "a beta only with allow_beta" {
  "$REPO/tests/vm/build_release.sh" v0.41.0-beta1 "$MGW_TEST_RELEASES"
  run "$ROOT/current/update.sh" -a
  [ "$status" -eq 0 ]
  check check_result=up_to_date
  "$ROOT/current/ctrl.sh" settings set allow_beta true > /dev/null
  run "$ROOT/current/update.sh" -a
  echo "$output"
  check check_version=v0.41.0-beta1
  [ "$(cat "$ROOT/v0_41_0-beta1_tmp/assets/version")" = "v0.41.0-beta1" ]
  "$ROOT/current/ctrl.sh" settings reset allow_beta > /dev/null
  rm -rf "$ROOT/v0_41_0-beta1_tmp" "$MGW_TEST_RELEASES/mgw_core_installer_v0.41.0-beta1.tar.gz"
}

@test "a newer release: downloaded into vX_Y_Z_tmp and handed over to stage two" {
  "$REPO/tests/vm/build_release.sh" v0.41.0 "$MGW_TEST_RELEASES"
  run "$ROOT/current/update.sh" -a
  echo "$output"
  # stage two of this version isn't implemented yet: S4
  [ "$status" -eq 1 ]
  check check_result=failed
  check check_version=v0.41.0
  check "check_step=the update script of v0.41.0 failed (exit code 1), see state/update"
  [ "$(cat "$ROOT/v0_41_0_tmp/assets/version")" = "v0.41.0" ]
  [ "$(readlink "$ROOT/v0_41_0_tmp/update.sh")" = "assets/scripts/update.sh" ]
  (cd "$ROOT/v0_41_0_tmp/assets" && sha256sum -c --quiet checksums)
  [ ! -e "/tmp/mgw_$U" ]
  [ "$(readlink "$ROOT/current")" = "v0_40_0" ]
}

@test "a leftover vX_Y_Z_tmp is replaced by the next run (S3)" {
  touch "$ROOT/v0_41_0_tmp/leftover"
  run "$ROOT/current/update.sh"
  [ ! -e "$ROOT/v0_41_0_tmp/leftover" ]
  [ -d "$ROOT/v0_41_0_tmp/assets" ]
}

@test "the retry limit: automatic runs skip the version, manual runs don't" {
  rm -rf "$ROOT/v0_41_0_tmp"
  printf '%s\n' version=v0_41_0 failures=3 > "$ROOT/state/attempts"
  run "$ROOT/current/update.sh" -a
  echo "$output"
  [ "$status" -eq 0 ]
  check check_result=skipped
  check "check_step=v0.41.0 failed 3 times"
  [ ! -e "$ROOT/v0_41_0_tmp" ]
  run "$ROOT/current/update.sh"
  [ -d "$ROOT/v0_41_0_tmp" ]
  rm -f "$ROOT/state/attempts"
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
  run "$REPO/assets/scripts/update.sh" -a "-path=$BATS_TEST_TMPDIR/old"
  [ "$status" -eq 1 ]
  [[ "$output" == *"can't migrate the installation"* ]]
  run "$REPO/assets/scripts/update.sh" -a "-path=$BATS_TEST_TMPDIR"
  [[ "$output" == *"isn't an installation of the old installer"* ]]
}

@test "an unfinished install is recovered under the update's lock first" {
  # a minimal core of folders only: its install never recorded success
  local fake="$DIR/fake"
  mkdir -p "$fake/state"
  cp -a "$ROOT/v0_40_0" "$fake/v0_40_0"
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
