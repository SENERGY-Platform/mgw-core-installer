#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# The parts of lib/docker.sh that don't need docker. Pulls are tested on the VM (tests/vm/docker.bats).

load helpers

docker_lib() {
  dsh "$1" file state net docker
}

@test "limit: a command within its limit" {
  run docker_lib 'limitRun 5 sh -c "echo out; exit 4"'
  [ "$status" -eq 4 ]
  [ "$output" = "out" ]
}

@test "limit: a command that runs out is killed with its children" {
  SECONDS=0
  run docker_lib 'limitRun 1 sh -c "sleep 30 & echo \$! > \"$BATS_TEST_TMPDIR/child\"; wait"'
  [ "$status" -eq 124 ]
  [[ "$output" == *"killed after 1s"* ]]
  [ "$SECONDS" -le 5 ]
  ! kill -0 "$(cat "$BATS_TEST_TMPDIR/child")" 2> /dev/null
}

@test "limit: 0 means no limit, the command runs in the foreground" {
  run docker_lib 'limitRun 0 sh -c "sleep 1.2; echo done"'
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]
}

@test "pull failures are classified by docker's message" {
  run docker_lib '
    dockerPullClassify "Error response from daemon: toomanyrequests: You have reached your pull rate limit."
    dockerPullClassify "Error response from daemon: pull access denied for x/y, repository does not exist or may require docker login"
    dockerPullClassify "Error response from daemon: manifest for nginx:0.0.0 not found: manifest unknown"
    dockerPullClassify "invalid reference format"
    dockerPullClassify "Error response from daemon: Get https://registry-1.docker.io/v2/: dial tcp: lookup registry-1.docker.io: no such host"
    dockerPullClassify "Error response from daemon: Get https://registry-1.docker.io/v2/: net/http: request canceled while waiting for connection"
    dockerPullClassify "killed after 1800s"'
  [ "$output" = "$(printf '%s\n' ratelimit permanent permanent permanent transient transient transient)" ]
}

@test "compose versions are compared by their numbers" {
  run docker_lib '
    for v in 2.8.0 v2.8.0 2.8.1 2.10.0 2.24.6-desktop.1 5.7.1 3; do
      dockerVersionAtLeast "$v" 2.8.0 && echo "$v yes" || echo "$v no"
    done
    for v in 2.7.9 v2.0.0 2.7 1.29.2 "" x; do
      dockerVersionAtLeast "$v" 2.8.0 && echo "$v yes" || echo "$v no"
    done'
  [ "$output" = "$(printf '%s\n' "2.8.0 yes" "v2.8.0 yes" "2.8.1 yes" "2.10.0 yes" "2.24.6-desktop.1 yes" \
    "5.7.1 yes" "3 yes" "2.7.9 no" "v2.0.0 no" "2.7 no" "1.29.2 no" " no" "x no")" ]
}

# a fake docker whose "compose version --short" prints $1 (nothing and exit 1 for "none")
fake_docker() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  if [ "$1" = "none" ]; then
    printf '#!/bin/sh\necho "docker: '"'"'compose'"'"' is not a docker command." >&2\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/docker"
  else
    printf '#!/bin/sh\n[ "$*" = "compose version --short" ] && echo %s\n' "$1" > "$BATS_TEST_TMPDIR/bin/docker"
  fi
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
}

@test "compose check: a current plugin passes" {
  for v in 2.9.0 v2.18.0 2.19.1 5.7.1; do
    fake_docker "$v"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" run docker_lib 'dockerComposeCheck'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
  done
}

@test "compose check: no plugin (only docker-compose v1) is refused" {
  fake_docker none
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run docker_lib 'dockerComposeCheck'
  [ "$status" -eq 1 ]
  [[ "$output" == "the docker compose plugin is required (docker-compose v1 isn't supported), 2.9.0 or newer"* ]]
}

@test "compose check: a plugin older than 2.9.0 is refused" {
  fake_docker v2.8.0
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run docker_lib 'dockerComposeCheck'
  [ "$status" -eq 1 ]
  [[ "$output" == "the docker compose plugin v2.8.0 is too old, 2.9.0 or newer is required"* ]]
}

@test "compose check: a release with a known bug is refused" {
  for v in 2.19.0 v2.25.0 5.1.0 5.1.1; do
    fake_docker "$v"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" run docker_lib 'dockerComposeCheck'
    [ "$status" -eq 1 ]
    [[ "$output" == "the docker compose plugin $v has a bug the installer can't work with"* ]]
  done
}

@test "compose check: no docker at all is refused" {
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  PATH="$BATS_TEST_TMPDIR/empty" run "$(command -v dash)" -c '. "$LIB/docker.sh"; dockerComposeCheck'
  [ "$status" -eq 1 ]
  [[ "$output" == "docker is required"* ]]
}
