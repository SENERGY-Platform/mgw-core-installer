#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# The retry rules of lib/net.sh against a local HTTP server (tests/unit/http_server.py).

load helpers

setup() {
  python3 "$BATS_TEST_DIRNAME/http_server.py" "$BATS_TEST_TMPDIR/port" &
  server_pid=$!
  local i=0
  while [ ! -s "$BATS_TEST_TMPDIR/port" ]; do
    sleep 0.05
    i=$((i + 1))
    [ "$i" -lt 100 ]
  done
  export URL="http://127.0.0.1:$(cat "$BATS_TEST_TMPDIR/port")" O="$BATS_TEST_TMPDIR/out"
}

teardown() {
  kill "$server_pid" 2> /dev/null || true
}

# runs $1 with short retry delays
net() {
  dsh 'net_retry_delays="0 0"; '"$1" net
}

requests() {
  curl -s "$URL/count/$1"
}

@test "success" {
  run net 'netFetch "$URL/ok" "$O" api'
  [ "$status" -eq 0 ]
  [ "$(cat "$O")" = "ok" ]
  [ ! -e "$O.err" ] && [ ! -e "$O.headers" ]
}

@test "a redirect is followed" {
  run net 'netDownload "$URL/redirect" "$O"'
  [ "$status" -eq 0 ]
  [ "$(cat "$O")" = "ok" ]
}

@test "a transient error is retried until it works" {
  run net 'netFetch "$URL/flaky/a/2" "$O" download'
  [ "$status" -eq 0 ]
  [ "$(cat "$O")" = "ok" ]
  [[ "$output" == *"attempt 1 failed (HTTP 503), retrying in 0s"* ]]
  [[ "$output" == *"attempt 2 failed"* ]]
}

@test "a transient error gives up after the last attempt, the error page isn't kept" {
  run net 'netFetch "$URL/status/503" "$O" api'
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed after 3 attempts (HTTP 503)"* ]]
  [ "$(requests status/503)" = "3" ]
  [ ! -e "$O" ]
}

@test "a permanent error fails at once" {
  for code in 404 401 400; do
    run net 'netFetch "$URL/status/'"$code"'" "$O" api'
    [ "$status" -eq 1 ]
    [[ "$output" == *"failed (HTTP $code)"* ]]
    [ "$(requests "status/$code")" = "1" ]
  done
  [ ! -e "$O" ]
}

@test "rate limits are not retried" {
  run net 'netFetch "$URL/github-ratelimit" "$O" api'
  [ "$status" -eq 3 ]
  [[ "$output" == *"rate limited (HTTP 403), not retrying"* ]]
  [ "$(requests github-ratelimit)" = "1" ]
  run net 'netFetch "$URL/status/429" "$O" api'
  [ "$status" -eq 3 ]
  [ "$(requests status/429)" = "1" ]
}

@test "a 403 that isn't a rate limit is permanent" {
  run net 'netFetch "$URL/status/403" "$O" api'
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed (HTTP 403)"* ]]
}

@test "a refused connection is transient" {
  run net 'netFetch "http://127.0.0.1:1/nothing" "$O" api'
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed after 3 attempts (HTTP 000"* ]]
}

@test "an API request that hangs times out and is retried" {
  # a listener that accepts and never answers
  python3 -c 'import socket,time; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(); open("'"$BATS_TEST_TMPDIR"'/hport","w").write(str(s.getsockname()[1])); time.sleep(30)' &
  local hang=$!
  while [ ! -s "$BATS_TEST_TMPDIR/hport" ]; do sleep 0.05; done
  export HANG="http://127.0.0.1:$(cat "$BATS_TEST_TMPDIR/hport")/"
  SECONDS=0
  run net 'net_api_timeout=1; net_retry_delays="0"; netFetch "$HANG" "$O" api'
  kill $hang
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed after 2 attempts (HTTP 000"* ]]
  [ "$SECONDS" -le 6 ]
}

@test "the asset URL of a release" {
  printf '%s' '{"assets":[{"name":"mgw_core_manager_v0.20.0_linux.tar.gz","browser_download_url":"https://x/linux.tar.gz"},{"name":"other.zip","browser_download_url":"https://x/other"}]}' > "$O"
  run net 'githubAssetUrl "$O" linux.tar.gz'
  [ "$status" -eq 0 ]
  [ "$output" = "https://x/linux.tar.gz" ]
  run net 'githubAssetUrl "$O" darwin.tar.gz'
  [ "$status" -eq 1 ]
}

@test "the asset suffix is matched literally" {
  printf '%s' '{"assets":[{"name":"v1.3.0Xtar.gz","browser_download_url":"https://x/wrong"}]}' > "$O"
  run net 'githubAssetUrl "$O" v1.3.0.tar.gz'
  [ "$status" -eq 1 ]
}
