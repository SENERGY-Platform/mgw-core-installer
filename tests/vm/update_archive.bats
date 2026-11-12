#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# The update from an extracted release archive on the test VM (m9-release.md): ./update.sh
# -path=<core root> in the archive root updates a core to the archive's version, with the guarantees
# of an update. A core installed from a test release v0.40.0; the archives are extracted test
# releases. The tests run in order.

load ../unit/helpers

# Subnets and ports: each file has ranges of its own, so files can run in parallel (tests/vm/run.sh
# -j); update_archive uses n from 15 and ports from 32000 (see the other files).

setup_file() {
  export REPO="$BATS_TEST_DIRNAME/../.."
  export DIR="/var/tmp/mgwt-update_archive-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  export A="a$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  export ROOT="$DIR/$A"
  local v
  for v in v0.40.0 v0.41.0 v0.42.0-alpha.1 v0.43.0; do
    "$REPO/.github/build_release.sh" "$v" "$BATS_FILE_TMPDIR/releases"
    mkdir -p "$BATS_FILE_TMPDIR/$v"
    tar -xzf "$BATS_FILE_TMPDIR/releases/mgw_core_installer_$v.tar.gz" -C "$BATS_FILE_TMPDIR/$v"
  done
  local n=$((RANDOM % 3 + 15))
  printf '%s\n' "install_dir=$DIR" "core_id=$A" "gateway_port=$((32000 + RANDOM % 1000))" "subnet_core=10.$n.0.0" \
    "subnet_gateway=10.$n.1.0" "subnet_module=10.$((n + 120)).0.0" autostart=true start_core=true \
    logrotate=false cron=false advertise=false > "$BATS_FILE_TMPDIR/a.conf"
  "$BATS_FILE_TMPDIR/v0.40.0/setup.sh" -c "$BATS_FILE_TMPDIR/a.conf" > "$BATS_FILE_TMPDIR/a.log" 2>&1
}

teardown_file() {
  rm -f "$ROOT/state/images"
  "$REPO/assets/scripts/uninstall.sh" -path="$ROOT" -y > /dev/null 2>&1 || true
  rm -rf "$DIR" "/tmp/mgw_$A"
}

# waits up to 5 minutes until the 7 long-running containers of the version folder $1 run
waitForRunning() {
  local i=0 n
  while [ $i -lt 60 ]; do
    n="$(docker ps --filter "label=com.docker.compose.project=mgw_${A}_$1" --filter status=running --format '{{.Label "core_srv_oneshot"}}' | grep -c '^$' || true)"
    [ "$n" -eq 7 ] && return 0
    sleep 5
    i=$((i + 1))
  done
  docker ps -a --filter "label=mgw_cid=$A" --format '{{.Names}} {{.Status}}'
  return 1
}

@test "the core runs v0.40.0" {
  grep -qx result=success "$ROOT/state/install"
  waitForRunning v0_40_0
}

@test "the archive root's update.sh updates the core to the archive's version" {
  run "$BATS_FILE_TMPDIR/v0.41.0/update.sh" -path="$ROOT"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"updating v0.40.0 to v0.41.0 from $BATS_FILE_TMPDIR/v0.41.0/assets"* ]]
  grep -qx kind=update "$ROOT/state/update" && grep -qx result=success "$ROOT/state/update"
  grep -qx from_version=v0.40.0 "$ROOT/state/update" && grep -qx to_version=v0.41.0 "$ROOT/state/update"
  [ "$(readlink "$ROOT/current")" = "v0_41_0" ]
  [ ! -e "$ROOT/v0_40_0" ] && [ ! -e "$ROOT/v0_41_0_tmp" ]
  waitForRunning v0_41_0
}

@test "the same version: nothing to do, restore.sh named for a rebuild" {
  cp "$ROOT/state/update" "$BATS_TEST_TMPDIR/update"
  run "$BATS_FILE_TMPDIR/v0.41.0/update.sh" -path="$ROOT"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"runs v0.41.0 already; to rebuild it, run"*"restore.sh -path=$ROOT"* ]]
  cmp "$ROOT/state/update" "$BATS_TEST_TMPDIR/update"
}

@test "an older version is refused, restore.sh -downgrade named" {
  run "$BATS_FILE_TMPDIR/v0.40.0/update.sh" -path="$ROOT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"v0.40.0 is older than v0.41.0"* ]] && [[ "$output" == *"-downgrade"* ]]
  [ "$(readlink "$ROOT/current")" = "v0_41_0" ] && [ ! -e "$ROOT/v0_40_0_tmp" ]
}

@test "an archive whose files don't match its checksums is refused before anything changes" {
  cp -a "$BATS_FILE_TMPDIR/v0.43.0" "$BATS_TEST_TMPDIR/damaged"
  echo "# changed" >> "$BATS_TEST_TMPDIR/damaged/assets/settings.defaults"
  run "$BATS_TEST_TMPDIR/damaged/update.sh" -path="$ROOT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"don't match the release's checksums"* ]]
  [ ! -e "$ROOT/v0_43_0_tmp" ] && [ "$(readlink "$ROOT/current")" = "v0_41_0" ]
}

@test "a failure after the switch: rolled back, as in any update" {
  run env MGW_TEST_FAIL_AT=activate "$BATS_FILE_TMPDIR/v0.43.0/update.sh" -path="$ROOT"
  echo "$output"
  [ "$status" -eq 1 ]
  grep -qx result=failed "$ROOT/state/update" && grep -qx rolled_back=true "$ROOT/state/update"
  [ "$(readlink "$ROOT/current")" = "v0_41_0" ] && [ ! -e "$ROOT/v0_43_0" ]
  waitForRunning v0_41_0
}

@test "an alpha can be chosen by hand, which update.sh never does by itself" {
  rm -f "$ROOT/state/attempts"
  run "$BATS_FILE_TMPDIR/v0.42.0-alpha.1/update.sh" -path="$ROOT"
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qx to_version=v0.42.0-alpha.1 "$ROOT/state/update" && grep -qx result=success "$ROOT/state/update"
  [ "$(readlink "$ROOT/current")" = "v0_42_0-alpha_1" ]
  waitForRunning v0_42_0-alpha_1
}

@test "a path that is neither a core root nor an old installation is refused" {
  run "$BATS_FILE_TMPDIR/v0.43.0/update.sh" -path="$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is neither a core root (<install dir>/<core id>) nor an installation of the old installer"* ]]
}

@test "without -path, the archive's update.sh names both ways to run it" {
  run "$BATS_FILE_TMPDIR/v0.43.0/update.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"as <core root>/current/update.sh, to update the core to the newest release"* ]]
  [[ "$output" == *"from an extracted release archive with -path=<core root>"* ]]
  [[ "$output" == *"-path=<install dir> migrates an installation of the old installer"* ]]
}
