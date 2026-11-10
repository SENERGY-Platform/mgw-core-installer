#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

load helpers

semver() {
  dsh "$1" semver
}

@test "valid and invalid versions" {
  for v in v0.0.0 v1.2.3 v0.33.0-beta2 v1.2.10-beta12 v10.20.30 v1.0.0-alpha1; do
    run semver "semverValid '$v'"
    [ "$status" -eq 0 ] || { echo "refused $v"; false; }
  done
  for v in "" 1.2.3 v1.2 v1.2.3.4 v1.2.x v1.2.3-rc1 v1.2.3-beta v1.2.3-beta1x v01.2.3 v1.02.3 "v1.2.3 " dev-1762650000 V1.2.3; do
    run semver "semverValid '$v'"
    [ "$status" -eq 1 ] || { echo "accepted '$v'"; false; }
  done
}

@test "pre-releases" {
  run semver "semverIsPre v1.2.3-beta1 && semverIsPre v1.2.3-alpha2 && ! semverIsPre v1.2.3"
  [ "$status" -eq 0 ]
}

@test "ordering" {
  ordered=(v0.9.9 v0.10.0 v1.0.0-alpha1 v1.0.0-alpha2 v1.0.0-beta1 v1.0.0-beta2 v1.0.0-beta10 v1.0.0 v1.0.1-beta1 v1.0.1 v1.2.9 v1.2.10 v2.0.0)
  local i j
  for ((i = 0; i < ${#ordered[@]} - 1; i++)); do
    j=$((i + 1))
    run semver "semverCompare '${ordered[$i]}' '${ordered[$j]}'"
    [ "$output" = "-1" ] || { echo "${ordered[$i]} < ${ordered[$j]}: $output"; false; }
    run semver "semverCompare '${ordered[$j]}' '${ordered[$i]}'"
    [ "$output" = "1" ] || { echo "${ordered[$j]} > ${ordered[$i]}: $output"; false; }
  done
  run semver "semverCompare v1.2.3-beta2 v1.2.3-beta2"
  [ "$output" = "0" ]
  run semver "semverLess v1.2.3 v1.2.4 && ! semverLess v1.2.4 v1.2.3 && ! semverLess v1.2.3 v1.2.3"
  [ "$status" -eq 0 ]
}

@test "comparing with something that isn't a release version fails" {
  run semver "semverCompare dev-1762650000 v1.0.0"
  [ "$status" -eq 1 ]
  run semver "semverLess dev-1762650000 v1.0.0"
  [ "$status" -eq 1 ]
}
