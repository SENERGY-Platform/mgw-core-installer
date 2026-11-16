#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# lib/host.sh: the supported system.

load helpers

# runs hostSupported against an os-release with the lines $@
supported() {
  printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/os-release"
  host_os_release="$BATS_TEST_TMPDIR/os-release" dsh 'hostSupported' host
}

@test "Debian 13 is supported, quoted or not" {
  run supported 'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"' 'VERSION_ID="13"' 'ID=debian'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  run supported 'VERSION_ID=13' 'ID="debian"'
  [ "$status" -eq 0 ]
}

@test "other systems are refused, named" {
  run supported 'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"' 'VERSION_ID="12"' 'ID=debian'
  [ "$status" -eq 1 ]
  [ "$output" = "Debian 13 is required, this is Debian GNU/Linux 12 (bookworm)" ]
  run supported 'PRETTY_NAME="Ubuntu 24.04.3 LTS"' 'VERSION_ID="24.04"' 'ID=ubuntu'
  [ "$status" -eq 1 ]
  [ "$output" = "Debian 13 is required, this is Ubuntu 24.04.3 LTS" ]
}

@test "without an os-release the system is unknown" {
  run env host_os_release="$BATS_TEST_TMPDIR/missing" dash -c '. "$LIB/host.sh"; hostSupported'
  [ "$status" -eq 1 ]
  [ "$output" = "Debian 13 is required, this is an unknown system" ]
}
