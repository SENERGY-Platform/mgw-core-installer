#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# The parts of lib/version.sh that don't need docker or the network: creating vX_Y_Z_tmp with the
# leftover rules (S3), and adding pinned keys. The rest is tested on the VM (tests/vm/version.bats).

load helpers

setup() {
  export ROOT="$BATS_TEST_TMPDIR/core" ASSETS="$BATS_TEST_DIRNAME/../../assets"
  mkdir -p "$ROOT/state"
}

version() {
  dsh "$1" file settings state host render reconcile net docker objects core version
}

@test "create: vX_Y_Z_tmp with the assets, the version file and the script links" {
  run version 'versionCreate "$ROOT" "$ASSETS" v0.41.0'
  [ "$status" -eq 0 ]
  [ -f "$ROOT/v0_41_0_tmp/assets/settings.defaults" ]
  [ "$(cat "$ROOT/v0_41_0_tmp/assets/version")" = "v0.41.0" ]
  for s in ctrl.sh update.sh restore.sh uninstall.sh; do
    [ "$(readlink "$ROOT/v0_41_0_tmp/$s")" = "assets/scripts/$s" ]
  done
}

@test "create: leftovers with the target names are removed (S3)" {
  mkdir -p "$ROOT/v0_41_0_tmp/leftover" "$ROOT/v0_41_0/leftover" "$ROOT/v0_40_0"
  ln -s v0_40_0 "$ROOT/current"
  run version 'versionCreate "$ROOT" "$ASSETS" v0.41.0'
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT/v0_41_0_tmp/leftover" ] && [ ! -e "$ROOT/v0_41_0" ]
  [ -d "$ROOT/v0_40_0" ]
}

@test "create: the folder current points to is never touched" {
  mkdir -p "$ROOT/v0_41_0/mine"
  ln -s v0_41_0 "$ROOT/current"
  run version 'versionCreate "$ROOT" "$ASSETS" v0.41.0'
  [ "$status" -eq 1 ]
  [[ "$output" == *"is the active version"* ]]
  [ -d "$ROOT/v0_41_0/mine" ]
}

@test "create: an invalid version is refused" {
  run version 'versionCreate "$ROOT" "$ASSETS" "V1.0"'
  [ "$status" -eq 1 ]
  [ -z "$(ls "$ROOT" | grep -v state)" ]
}

@test "pin: keys are added only if missing, never changed" {
  printf '%s\n' 'gateway_port=9090' 'core_id=abc' > "$ROOT/state/settings"
  printf '%s\n' '# comment' 'gateway_tls=false' 'gateway_port=8080' '' > "$BATS_TEST_TMPDIR/pinned"
  run version 'versionPin "$ROOT/state/settings" "$BATS_TEST_TMPDIR/pinned"'
  [ "$status" -eq 0 ]
  [ "$(cat "$ROOT/state/settings")" = "$(printf '%s\n' gateway_port=9090 core_id=abc gateway_tls=false)" ]
}

@test "the shipped settings.pinned parses (no keys yet)" {
  run version 'versionPin "$ROOT/state/settings" "$ASSETS/settings.pinned"'
  [ "$status" -eq 0 ]
  [ ! -s "$ROOT/state/settings" ]
}

core_target() {
  dsh 'settingsLoad "$BATS_TEST_TMPDIR/defaults" "" || exit 9; '"$1" file settings state core
}

@test "target state: written for this boot, read back" {
  printf 'autostart=false\n' > "$BATS_TEST_TMPDIR/defaults"
  run core_target 'coreSetTarget "$ROOT" running && coreTarget "$ROOT"'
  [ "$output" = "running" ]
  grep -qx "boot_id=$(cat /proc/sys/kernel/random/boot_id)" "$ROOT/state/target_state"
  run core_target 'coreSetTarget "$ROOT" stopped && coreTarget "$ROOT"'
  [ "$output" = "stopped" ]
}

@test "target state: from an earlier boot, missing or damaged, autostart decides" {
  printf '%s\n' state=stopped boot_id=from-an-earlier-boot > "$ROOT/state/target_state"
  printf 'autostart=true\n' > "$BATS_TEST_TMPDIR/defaults"
  run core_target 'coreTarget "$ROOT"'
  [ "$output" = "running" ]
  printf 'autostart=false\n' > "$BATS_TEST_TMPDIR/defaults"
  printf '%s\n' state=running boot_id=from-an-earlier-boot > "$ROOT/state/target_state"
  run core_target 'coreTarget "$ROOT"'
  [ "$output" = "stopped" ]
  rm "$ROOT/state/target_state"
  run core_target 'coreTarget "$ROOT"'
  [ "$output" = "stopped" ]
  printf '%s\n' state=paused "boot_id=$(cat /proc/sys/kernel/random/boot_id)" > "$ROOT/state/target_state"
  run core_target 'coreTarget "$ROOT"'
  [ "$output" = "stopped" ]
}
