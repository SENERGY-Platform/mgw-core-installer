#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# The volume check of the release (.github/check_volumes.sh, m8-release.md finding 5) on the test VM:
# every volume a core image declares must be mounted by the compose file. Needs the registries, not
# the core; no subnets or ports of its own.

load ../unit/helpers

setup_file() {
  export REPO="$BATS_TEST_DIRNAME/../.."
}

@test "today's images and compose file pass" {
  run "$REPO/.github/check_volumes.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"every volume the core images declare is mounted"* ]]
}

@test "a declared path the compose file doesn't mount fails the check and is named" {
  cp -a "$REPO/assets" "$BATS_TEST_TMPDIR/assets"
  sed -i '\|- mysqldb-data:/var/lib/mysql|d' "$BATS_TEST_TMPDIR/assets/templates/container/docker-compose.yml.tmpl"
  run "$REPO/.github/check_volumes.sh" "$BATS_TEST_TMPDIR/assets"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"service mysqldb: image mysql:"*" declares /var/lib/mysql, which the compose file doesn't mount"* ]]
  [ "$(grep -c "doesn't mount" <<< "$output")" -eq 1 ]
}

@test "an exception with a reason lets a path pass, one without a reason is refused" {
  cp -a "$REPO/assets" "$BATS_TEST_TMPDIR/assets"
  sed -i '\|- mysqldb-data:/var/lib/mysql|d' "$BATS_TEST_TMPDIR/assets/templates/container/docker-compose.yml.tmpl"
  printf '%s\n' "# a comment" "mysqldb /var/lib/mysql the test needs it" > "$BATS_TEST_TMPDIR/exceptions"
  run "$REPO/.github/check_volumes.sh" "$BATS_TEST_TMPDIR/assets" "$BATS_TEST_TMPDIR/exceptions"
  echo "$output"
  [ "$status" -eq 0 ]
  echo "mysqldb /var/lib/mysql" > "$BATS_TEST_TMPDIR/exceptions"
  run "$REPO/.github/check_volumes.sh" "$BATS_TEST_TMPDIR/assets" "$BATS_TEST_TMPDIR/exceptions"
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 1: '<service> <path> <reason>' expected, the reason is mandatory"* ]]
}
