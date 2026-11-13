#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# lib/log.sh: the scripts' log, <core root>/log/scripts.log. The scripts under test are written into
# the test's folder and run under dash.

load helpers

setup() {
  export ROOT="$BATS_TEST_TMPDIR/root" LOGF="$BATS_TEST_TMPDIR/root/log/scripts.log"
  mkdir -p "$ROOT/log"
  unset MGW_LOG_PID MGW_LOG_READER
}

# writes the script $1 (a name in the test folder) with the body $2, sourcing lib/log.sh
script() {
  printf '#!/bin/sh\n. "$LIB/log.sh"\n%s\n' "$2" > "$BATS_TEST_TMPDIR/$1"
  chmod +x "$BATS_TEST_TMPDIR/$1"
}

@test "stdout and stderr go to the terminal and, stamped, into the log; the exit code stays" {
  script a.sh 'logCore "$ROOT" a.sh; echo out; echo err >&2; exit 3'
  run dash "$BATS_TEST_TMPDIR/a.sh"
  [ "$status" -eq 3 ]
  [[ "$output" == *out* ]] && [[ "$output" == *err* ]]
  grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z a\.sh\[[0-9]+\]: out$' "$LOGF"
  grep -Eq ' a\.sh\[[0-9]+\]: err$' "$LOGF"
}

@test "the log is appended to, a last line without a line break is kept" {
  echo "an earlier line" > "$LOGF"
  script a.sh 'logCore "$ROOT" a.sh; printf "no line break"'
  run dash "$BATS_TEST_TMPDIR/a.sh"
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$LOGF")" = "an earlier line" ]
  grep -q ': no line break$' "$LOGF"
}

@test "a prompt without a line break reaches the terminal before the answer is read" {
  script a.sh 'logCore "$ROOT" a.sh; printf "continue? (Y/n): " >&2; read -r answer; echo "answer $answer"'
  mkfifo "$BATS_TEST_TMPDIR/in"
  dash "$BATS_TEST_TMPDIR/a.sh" < "$BATS_TEST_TMPDIR/in" > "$BATS_TEST_TMPDIR/term" 2>&1 &
  local pid=$! i=0
  exec 6> "$BATS_TEST_TMPDIR/in"
  until grep -q "continue? (Y/n): " "$BATS_TEST_TMPDIR/term"; do
    sleep 0.1
    i=$((i + 1))
    [ $i -lt 30 ] || { exec 6>&-; false; }
  done
  echo y >&6
  exec 6>&-
  wait "$pid"
  grep -q "answer y" "$BATS_TEST_TMPDIR/term"
}

@test "a logging script started by a logging one logs with its own name, without duplicates" {
  script child.sh 'logCore "$ROOT" child.sh; echo from the child'
  script parent.sh 'logCore "$ROOT" parent.sh; echo from the parent; "$(dirname "$0")/child.sh"; echo parent again'
  run dash "$BATS_TEST_TMPDIR/parent.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"from the child"* ]]
  [ "$(grep -c "from the child" "$LOGF")" -eq 1 ]
  grep -Eq ' child\.sh\[[0-9]+\]: from the child$' "$LOGF"
  grep -Eq ' parent\.sh\[[0-9]+\]: parent again$' "$LOGF"
}

@test "a script that execs another keeps one log and one reader" {
  script second.sh 'logCore "$ROOT" second.sh; echo after the exec'
  script first.sh 'logCore "$ROOT" first.sh; echo before the exec; exec "$(dirname "$0")/second.sh"'
  run dash "$BATS_TEST_TMPDIR/first.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c "after the exec" "$LOGF")" -eq 1 ]
  # the lines keep the name of the script that started the log
  grep -Eq ' first\.sh\[[0-9]+\]: after the exec$' "$LOGF"
}

@test "without a log folder the script runs as before" {
  rm -rf "$ROOT/log"
  script a.sh 'logCore "$ROOT" a.sh; echo out; exit 2'
  run dash "$BATS_TEST_TMPDIR/a.sh"
  [ "$status" -eq 2 ]
  [ "$output" = "out" ]
  [ ! -e "$LOGF" ]
}

@test "a line for the terminal only never reaches the log" {
  script a.sh 'logCore "$ROOT" a.sh; echo visible; logTerminalOnly "password: secret"'
  run dash "$BATS_TEST_TMPDIR/a.sh"
  [[ "$output" == *"password: secret"* ]]
  grep -q ": visible$" "$LOGF"
  ! grep -q secret "$LOGF"
}

@test "a process left running with the log's descriptors doesn't hold the script for longer than 5s" {
  script a.sh 'logCore "$ROOT" a.sh; sleep 31 & echo started'
  local start=$SECONDS rc=0
  # into a file, not through run's pipe: the sleep keeps the terminal open, which a pipe reader waits
  # for (a real terminal doesn't)
  dash "$BATS_TEST_TMPDIR/a.sh" > "$BATS_TEST_TMPDIR/term" 2>&1 || rc=$?
  pkill -f "sleep 31" || true
  [ "$rc" -eq 0 ]
  [ $((SECONDS - start)) -lt 15 ]
  grep -q started "$BATS_TEST_TMPDIR/term"
}

@test "a terminal that is a socket (systemd's journal) gets the output too, the FIFOs are removed" {
  script a.sh 'logCore "$ROOT" a.sh; echo through the socket'
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  run python3 -c '
import socket, subprocess, sys
a, b = socket.socketpair()
p = subprocess.Popen(["dash", sys.argv[1]], stdout=a.fileno(), stderr=a.fileno())
a.close()
p.wait()
data = b""
while True:
    chunk = b.recv(4096)
    if not chunk:
        break
    data += chunk
sys.stdout.write(data.decode())
' "$BATS_TEST_TMPDIR/a.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"through the socket"* ]]
  grep -q ": through the socket$" "$LOGF"
  [ -z "$(ls -A "$TMPDIR")" ]
}
