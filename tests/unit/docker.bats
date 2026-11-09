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
