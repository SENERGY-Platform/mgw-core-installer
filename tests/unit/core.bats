#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# Version folder names. Starting and stopping the core is tested on the VM (tests/vm/core.bats).

load helpers

@test "version folder names" {
  run dsh 'versionFolder v1.2.3; versionFolder v0.33.0-beta2; versionFolder v1.2.10-beta12; versionFolder v0.40.0-beta.1; versionFolder dev-1762650000' core
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' v1_2_3 v0_33_0-beta2 v1_2_10-beta12 v0_40_0-beta_1 dev-1762650000)" ]
}

@test "versions that can't be part of a compose project name are refused" {
  for v in "" V1.2.3 "v1.2.3 x" "v1/2" "-v1" "_v1" "v1.2.3+build"; do
    run dsh "versionFolder '$v'" core
    [ "$status" -eq 1 ] || { echo "accepted: '$v'"; false; }
  done
}
