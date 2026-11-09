#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

load helpers

setup() {
  export L="$BATS_TEST_TMPDIR/lock" R="$BATS_TEST_TMPDIR/ready"
  holder_pid=""
}

teardown() {
  if [ "$holder_pid" != "" ]; then
    kill "$holder_pid" 2> /dev/null || true
    wait "$holder_pid" 2> /dev/null || true
  fi
}

lock() {
  dsh "$1" file state lock
}

# starts a process that takes the lock as $1 and keeps it until killed. dash replaces itself with
# sleep, which keeps descriptor 9, so killing holder_pid releases the lock.
hold() {
  dash -c ". \"\$LIB/file.sh\"; . \"\$LIB/state.sh\"; . \"\$LIB/lock.sh\"
    lockAcquire \"\$L\" $1 || exit 1
    : > \"\$R\"
    exec sleep 60" &
  holder_pid=$!
  local i=0
  while [ ! -e "$R" ]; do
    sleep 0.05
    i=$((i + 1))
    [ "$i" -lt 100 ] || return 1
  done
}

@test "acquire records holder, pid and since" {
  run lock 'lockAcquire "$L" update && cat "$L" && echo "pid $$"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "holder=update" ]
  [ "${lines[1]#pid=}" = "${lines[3]#pid }" ]
  [[ "${lines[2]}" =~ ^since=20[0-9-]+T[0-9:]+Z$ ]]
}

@test "a held lock is refused after waiting two seconds, with the holder named" {
  hold update
  local before
  before="$(cat "$L")"
  SECONDS=0
  run lock 'lockAcquire "$L" ctrl.sh'
  [ "$status" -eq 2 ]
  [ "$SECONDS" -ge 1 ] && [ "$SECONDS" -le 4 ]
  [[ "$output" == "locked by update (pid $holder_pid) since 20"*", giving up" ]]
  # the refused attempt neither emptied nor changed the file
  [ "$(cat "$L")" = "$before" ]
}

@test "a lock released within the wait is taken" {
  hold update
  (sleep 0.5; kill "$holder_pid") &
  run lock 'lockAcquire "$L" ctrl.sh && cat "$L"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "holder=ctrl.sh" ]
}

@test "a killed holder leaves no lock, only its entry" {
  hold update
  kill "$holder_pid"
  wait "$holder_pid" 2> /dev/null || true
  holder_pid=""
  grep -qx holder=update "$L"
  run lock 'lockHeld "$L"'
  [ "$status" -eq 1 ]
  run lock 'lockDescribe "$L"'
  [ "$output" = "not locked (last holder: update)" ]
  run lock 'lockAcquire "$L" ctrl.sh'
  [ "$status" -eq 0 ]
}

@test "held: yes while held, no without a lock file" {
  run lock 'lockHeld "$L"'
  [ "$status" -eq 1 ]
  hold update
  run lock 'lockHeld "$L"'
  [ "$status" -eq 0 ]
  run lock 'lockDescribe "$L"'
  [[ "$output" == "locked by update (pid $holder_pid) since 20"* ]]
}

@test "checking the lock doesn't take it" {
  printf '%s\n' holder=old > "$L"
  run lock 'lockHeld "$L"; lockAcquire "$L" update'
  [ "$status" -eq 0 ]
}

@test "release keeps the entry but frees the lock" {
  run lock 'lockAcquire "$L" update && lockRelease && lockHeld "$L"; echo "held=$?"; cat "$L"'
  [ "${lines[0]}" = "held=1" ]
  [ "${lines[1]}" = "holder=update" ]
}

@test "stage two confirms the lock it inherited and records itself" {
  run lock 'lockAcquire "$L" update || exit 1
    dash -c ". \"\$LIB/file.sh\"; . \"\$LIB/state.sh\"; . \"\$LIB/lock.sh\"
      lockInherited \"\$L\" update && echo confirmed && cat \"\$L\" && echo \"pid \$\$\""'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "confirmed" ]
  [ "${lines[1]}" = "holder=update" ]
  [ "${lines[2]#pid=}" = "${lines[4]#pid }" ]
}

@test "without the inherited descriptor there is nothing to confirm" {
  run lock 'lockAcquire "$L" update || exit 1
    dash -c ". \"\$LIB/file.sh\"; . \"\$LIB/state.sh\"; . \"\$LIB/lock.sh\"
      lockInherited \"\$L\" update" 9>&-'
  [ "$status" -eq 1 ]
  run lock 'MGW_LOCK_HELD="$L" lockInherited "$L" update'
  [ "$status" -eq 1 ]
}

# lockRelease unlocks explicitly, which frees the lock even for a child sharing descriptor 9. What
# matters is a holder that ends without releasing (killed, crashed): then only closing descriptor 9
# in the child keeps the lock from outliving the holder.
@test "a child started without descriptor 9 doesn't keep the lock after the holder ends" {
  run lock 'lockAcquire "$L" update || exit 1
    sleep 30 9>&- > /dev/null 2>&1 &
    echo $! > "$BATS_TEST_TMPDIR/child"'
  [ "$status" -eq 0 ]
  run lock 'lockHeld "$L"'
  kill "$(cat "$BATS_TEST_TMPDIR/child")"
  [ "$status" -eq 1 ]
}

@test "a child that keeps descriptor 9 keeps the lock after the holder ends" {
  run lock 'lockAcquire "$L" update || exit 1
    sleep 30 > /dev/null 2>&1 &
    echo $! > "$BATS_TEST_TMPDIR/child"'
  [ "$status" -eq 0 ]
  run lock 'lockHeld "$L"'
  kill "$(cat "$BATS_TEST_TMPDIR/child")"
  [ "$status" -eq 0 ]
}

@test "a lock file that can't be opened fails without ending the shell" {
  run lock 'lockAcquire "$BATS_TEST_TMPDIR/missing/lock" update; echo "rc=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"cannot open lock file"* ]]
  [[ "$output" == *"rc=1" ]]
}
