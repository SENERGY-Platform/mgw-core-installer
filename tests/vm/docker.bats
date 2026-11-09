#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# Image pulls with the real docker on the test VM (sudo bats tests/vm). Needs access to Docker Hub.

load ../unit/helpers

setup() {
  export I="$BATS_TEST_TMPDIR/images"
}

docker_lib() {
  dsh 'net_retry_delays="0 0"; '"$1" file state net docker
}

@test "pulled images are recorded, each once" {
  run docker_lib 'dockerPullImages "$I" 600 busybox:1.37 busybox:1.37'
  [ "$status" -eq 0 ]
  [ "$(cat "$I")" = "busybox:1.37" ]
  docker image inspect busybox:1.37 > /dev/null
}

@test "an image that doesn't exist fails at once, but stays recorded" {
  run docker_lib 'dockerPullImages "$I" 600 mgwtest/does-not-exist:1 busybox:1.37'
  [ "$status" -eq 1 ]
  [[ "$output" == *"pulling mgwtest/does-not-exist:1 failed: "*"repository does not exist"* ]]
  [[ "$output" != *"retrying"* ]]
  # recorded before its pull; the pulls after a failure don't run
  [ "$(cat "$I")" = "mgwtest/does-not-exist:1" ]
}

@test "a pull that runs out of time is killed and retried" {
  docker image rm -f mgwtest/never:1 > /dev/null 2>&1 || true
  # an unroutable registry: every attempt hangs until its limit
  SECONDS=0
  run docker_lib 'net_retry_delays="0"; dockerPull 10.255.255.1:5000/mgwtest/never:1 2'
  [ "$status" -eq 1 ]
  [[ "$output" == *"killed after 2s"* ]]
  [[ "$output" == *"failed after 2 attempts"* ]]
  [ "$SECONDS" -le 20 ]
}

@test "compose runs with a limit" {
  mkdir -p "$BATS_TEST_TMPDIR/p"
  printf '%s\n' 'name: mgwtestcompose' 'services:' '  s:' '    image: busybox:1.37' > "$BATS_TEST_TMPDIR/p/c.yml"
  run docker_lib 'dockerCompose 60 -f "$BATS_TEST_TMPDIR/p/c.yml" config --services'
  [ "$status" -eq 0 ]
  [ "$output" = "s" ]
}
