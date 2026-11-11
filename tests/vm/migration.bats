#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# The migration of an old installation on the test VM (PLAN.md 15, m7-migration.md): a real old
# release installed from its GitHub archive, migrated to a test release v0.40.0 through the real old
# stage one (<install dir>/update.sh). The old lib/github.sh is pointed at the GitHub mock before the
# old setup.sh runs, so the old installer fetches its binaries and the test releases from the mock;
# everything else of the old code runs unchanged (m7-migration.md, finding 5). The tests run in order.

load ../unit/helpers
load github

# Subnets and ports: each file has ranges of its own, so files can run in parallel (tests/vm/run.sh
# -j); migration uses n from 105 and ports from 27000 (see the other files).

OLD_VERSION=v0.31.1

# prints the archive of the old release $1, downloaded once into the test cache
oldArchive() {
  local f="$MGW_TEST_CACHE/old/mgw_core_installer_$1.tar.gz"
  if [ ! -s "$f" ]; then
    mkdir -p "${f%/*}"
    curl -fsSL -o "$f.tmp.$$" "https://github.com/SENERGY-Platform/mgw-core-installer/releases/download/$1/mgw_core_installer_$1.tar.gz"
    mv "$f.tmp.$$" "$f"
  fi
  echo "$f"
}

# installs the old release $1 into $DIR with the old setup.sh, its lib/github.sh pointed at the mock
installOld() {
  local x="$BATS_FILE_TMPDIR/old-$1" n=$((RANDOM % 3 + 105))
  rm -rf "$x"
  mkdir -p "$x"
  tar -xzf "$(oldArchive "$1")" -C "$x"
  sed -i "s|https://api.github.com|$MGW_TEST_GITHUB_API|" "$x/assets/scripts/lib/github.sh"
  # the old config file is sourced shell code
  printf '%s\n' "base_path=$DIR" "core_id=$S" "gateway_port=$((27000 + RANDOM % 1000))" "subnet_core=10.$n.0.0" \
    "subnet_gateway=10.$n.1.0" "subnet_module=10.$((n + 120)).0.0" systemd=true logrotate=false cron=false \
    advertise=false allow_beta=false skip_pgk_install_confirm=true start_core=true > "$BATS_FILE_TMPDIR/old.conf"
  "$x/setup.sh" -c "$BATS_FILE_TMPDIR/old.conf" > "$BATS_FILE_TMPDIR/old-setup.log" 2>&1 || { tail -n 30 "$BATS_FILE_TMPDIR/old-setup.log" >&3; return 1; }
}

# removes whatever is installed in $DIR: the new layout with its uninstall.sh, the old one with the old
# uninstall.sh
removeInstallation() {
  if [ -e "$DIR/current" ]; then
    rm -f "$DIR/state/images"
    "$REPO/assets/scripts/uninstall.sh" -path="$DIR" -y > /dev/null 2>&1 || true
  elif [ -x "$DIR/uninstall.sh" ]; then
    "$DIR/uninstall.sh" -path="$DIR" -y > /dev/null 2>&1 || true
  fi
  rm -rf "$DIR" "/mnt/mgw_$S" /tmp/mgw-update
}

setup_file() {
  export REPO="$BATS_TEST_DIRNAME/../.."
  export MGW_TEST_RELEASES="$BATS_FILE_TMPDIR/releases"
  startGithubMock
  export DIR="/var/tmp/mgwt-migration-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  export S="m$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  "$REPO/tests/vm/build_release.sh" v0.40.0 "$MGW_TEST_RELEASES"
  installOld "$OLD_VERSION"
}

teardown_file() {
  stopGithubMock
  removeInstallation
}

# returns 0 if the old core runs: its core-manager unit is active and its containers run
oldRunning() {
  systemctl is-active --quiet "mgw_$S-core-manager.service" || return 1
  local i=0
  while [ $i -lt 30 ]; do
    [ "$(docker ps -q --filter "name=^mgw_$S-nginx\$" --filter status=running)" != "" ] && return 0
    sleep 2
    i=$((i + 1))
  done
  return 1
}

# returns 0 if the migration left nothing of the new layout but state/update and state/lock
nothingNew() {
  [ ! -e "$DIR/current" ] && [ ! -e "$DIR/v0_40_0" ] && [ ! -e "$DIR/v0_40_0_tmp" ] && [ ! -e "$DIR/state/settings" ]
}

# prints the field $1 of the old .update_status
oldStatus() {
  jq -r ".$1" "$DIR/.update_status"
}

@test "the old installation runs" {
  [ "$(cat "$DIR/.version")" = "$OLD_VERSION" ]
  [ -f "$DIR/.settings" ] && [ ! -e "$DIR/state" ]
  oldRunning
}

@test "a path that differs from the new layout: refused before anything changes" {
  cp "$DIR/.settings" "$BATS_TEST_TMPDIR/settings"
  sed -i "s|^log_path=.*|log_path=/var/log/mgw_$S|" "$DIR/.settings"
  run "$DIR/update.sh" -a
  cp "$BATS_TEST_TMPDIR/settings" "$DIR/.settings"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"log_path is '/var/log/mgw_$S', the new layout needs $DIR/log"* ]]
  [ "$(oldStatus result)" = "failed" ]
  [[ "$(oldStatus step)" == *"log_path is '/var/log/mgw_$S'"* ]]
  [ "$(oldStatus from_version)" = "$OLD_VERSION" ] && [ "$(oldStatus to_version)" = "v0.40.0" ]
  [ ! -e "$DIR/state" ]
  oldRunning
}

@test "an installation older than v0.30.0-alpha1: refused with the way forward" {
  echo v0.23.0 > "$DIR/.version"
  run "$DIR/update.sh" -a
  echo "$OLD_VERSION" > "$DIR/.version"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"older than v0.30.0-alpha1"* ]] && [[ "$output" == *"update it by hand"* ]]
  [[ "$(oldStatus step)" == *"older than v0.30.0-alpha1"* ]]
  [ ! -e "$DIR/state" ]
  oldRunning
}

@test "a held lock: the second run ends there, nothing changed" {
  mkdir "$DIR/state"
  flock "$DIR/state/lock" sleep 30 &
  local holder=$!
  sleep 1
  run "$DIR/update.sh" -a
  kill "$holder" 2> /dev/null || true
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"another update or migration of $DIR is running"* ]]
  [ ! -e "$DIR/state/update" ]
  nothingNew
  rm -rf "$DIR/state"
}

@test "a copy that doesn't match its checksums: undone, the old core untouched" {
  run env MGW_TEST_FAIL_AT=checksums "$DIR/update.sh" -a
  echo "$output"
  [ "$status" -eq 1 ]
  grep -qx result=failed "$DIR/state/update" && grep -qx kind=migration "$DIR/state/update"
  grep -qx rolled_back=false "$DIR/state/update" && grep -qx writer=v0_40_0 "$DIR/state/update"
  grep -q "^step=the copy of v0.40.0 doesn't match its checksums" "$DIR/state/update"
  [ ! -e "$DIR/state/attempts" ] || ! grep -q v0_40_0 "$DIR/state/attempts"
  [[ "$(oldStatus step)" == *"doesn't match its checksums"* ]]
  nothingNew
  oldRunning
}

@test "the real old stage one: the migration runs on from its copy in the install directory" {
  run "$DIR/update.sh" -a
  echo "$output"
  [ "$status" -eq 1 ]
  # the run from the copy wrote this; until the migration in place exists it stops there
  grep -q "^step=the migration in place isn't implemented yet" "$DIR/state/update"
  grep -qx was_running=true "$DIR/state/update"
  grep -qx "from_version=$OLD_VERSION" "$DIR/state/update"
  [[ "$(oldStatus step)" == *"isn't implemented yet"* ]]
  nothingNew
  oldRunning
}
