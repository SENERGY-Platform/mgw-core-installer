#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# The install record and its cleanup with folders, links and files. Docker objects, units and mounts
# are tested on the VM (tests/vm/objects.bats).

load helpers

setup() {
  export ROOT="$BATS_TEST_TMPDIR/core" R="$BATS_TEST_TMPDIR/core/state/install"
  mkdir -p "$ROOT/state"
  printf '%s\n' 'core_name=' > "$BATS_TEST_TMPDIR/defaults"
}

objects() {
  dsh 'settingsLoad "$BATS_TEST_TMPDIR/defaults" "" || exit 9; '"$1" file settings state host objects
}

@test "the record: begin, objects in order and once, result" {
  run objects '
    installRecordBegin "$R" v1_3_0 install
    installRecordAdd "$R" folder:.
    installRecordAdd "$R" folder:log
    installRecordAdd "$R" folder:log
    installRecordAdd "$R" volume:mgw_abc_mysqldb-data
    installRecordResult "$R" success'
  [ "$status" -eq 0 ]
  grep -qx 'writer=v1_3_0' "$R"
  grep -qx 'mode=install' "$R"
  grep -qx 'result=success' "$R"
  grep -q '^started=20' "$R" && grep -q '^finished=20' "$R"
  [ "$(grep '^created=' "$R")" = "$(printf '%s\n' created=folder:. created=folder:log created=volume:mgw_abc_mysqldb-data)" ]
}

@test "create functions record first, and only what they create" {
  mkdir -p "$ROOT/existing"
  run objects '
    installRecordBegin "$R" v1_3_0 install
    objects_record="$R"
    objectsFolder "$ROOT" existing
    objectsFolder "$ROOT" mounts/nginx
    echo content | objectsFile "$ROOT/some.file" 644'
  [ "$status" -eq 0 ]
  [ "$(grep '^created=' "$R")" = "$(printf '%s\n' created=folder:mounts/nginx "created=file:$ROOT/some.file")" ]
  [ -d "$ROOT/mounts/nginx" ]
  [ "$(stat -c %a "$ROOT/some.file")" = "644" ]
}

@test "an object recorded in a subshell isn't lost by the next one" {
  run objects '
    installRecordBegin "$R" v1_3_0 install
    objects_record="$R"
    echo x | objectsFile "$ROOT/piped" 644
    objectsFolder "$ROOT" after'
  [ "$status" -eq 0 ]
  [ "$(grep '^created=' "$R")" = "$(printf '%s\n' "created=file:$ROOT/piped" created=folder:after)" ]
}

@test "nothing is created if it can't be recorded" {
  run objects '
    installRecordBegin "$R" v1_3_0 install
    objects_record="$R"
    chmod 500 "$ROOT/state"
    objectsFolder "$ROOT" log; echo "rc=$?"
    chmod 700 "$ROOT/state"'
  [[ "$output" == *"rc=1"* ]]
  [ ! -e "$ROOT/log" ]
}

@test "without a record nothing is recorded" {
  run objects 'objectsFolder "$ROOT" log'
  [ "$status" -eq 0 ]
  [ -d "$ROOT/log" ] && [ ! -e "$R" ]
}

@test "cleanup removes everything listed in reverse order, the core root last" {
  run objects '
    installRecordBegin "$R" v1_3_0 install
    objects_record="$R"
    installRecordAdd "$R" folder:.
    objectsFolder "$ROOT" log
    objectsFolder "$ROOT" v1_3_0/bin
    installRecordAdd "$R" link:current && ln -s v1_3_0 "$ROOT/current"
    installCleanup "$ROOT" "$R"'
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT" ]
}

@test "cleanup keeps the core root and lists what it couldn't remove" {
  run objects '
    installRecordBegin "$R" v1_3_0 install
    objects_record="$R"
    installRecordAdd "$R" folder:.
    objectsFolder "$ROOT" log
    objectsFolder "$ROOT" stuck/inner
    touch "$ROOT/stuck/inner/f"
    chmod 500 "$ROOT/stuck/inner"
    objectsFolder "$ROOT" v1_3_0
    installCleanup "$ROOT" "$R"; echo "rc=$?"
    chmod 700 "$ROOT/stuck/inner"'
  [[ "$output" == *"could not remove folder:stuck/inner"* ]]
  [[ "$output" == *"rc=1"* ]]
  [ -d "$ROOT" ] && [ ! -e "$ROOT/log" ] && [ ! -e "$ROOT/v1_3_0" ]
  grep -qx 'result=failed' "$R"
  [ "$(grep '^created=' "$R")" = "$(printf '%s\n' created=folder:. created=folder:stuck/inner)" ]
}

@test "cleanup of a record without the core root keeps the record at failed" {
  run objects '
    installRecordBegin "$R" v1_3_0 install
    objects_record="$R"
    objectsFolder "$ROOT" log
    installCleanup "$ROOT" "$R"'
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT/log" ]
  grep -qx 'result=failed' "$R"
}

@test "remove refuses paths outside the core root" {
  for o in "folder:" "folder:/etc" "folder:.." "folder:a/../.." "link:../x" "file:relative"; do
    run objects 'objectsRemove "$ROOT" "'"$o"'"'
    [ "$status" -eq 1 ] || { echo "accepted $o"; false; }
  done
  run objects 'objectsRemove "" folder:.'
  [ "$status" -eq 1 ]
  run objects 'objectsRemove / folder:.'
  [ "$status" -eq 1 ]
  [ -d "$ROOT" ]
}

@test "remove tolerates objects that don't exist" {
  run objects 'objectsRemove "$ROOT" folder:missing && objectsRemove "$ROOT" "file:$ROOT/missing" && objectsRemove "$ROOT" link:missing'
  [ "$status" -eq 0 ]
}

@test "the core's networks with their subnets" {
  printf '%s\n' 'core_name=mgw_abc' 'subnet_core=10.0.0.0' 'subnet_module=10.1.0.0' 'subnet_gateway=10.10.0.0' > "$BATS_TEST_TMPDIR/defaults"
  run objects 'objectsNetworks'
  [ "$output" = "$(printf '%s\n' 'mgw_abc-0-gateway-net 10.10.0.0/28' 'mgw_abc-1-core-net 10.0.0.0/28' 'mgw_abc-2-module-net 10.1.0.0/16')" ]
}

@test "the links into current/config are removed from /etc, nothing else" {
  export host_systemd_path="$BATS_TEST_TMPDIR/etc/systemd" host_logrotated_path="$BATS_TEST_TMPDIR/etc/logrotate.d" \
    host_cron_path="$BATS_TEST_TMPDIR/etc/cron.daily" host_avahi_path="$BATS_TEST_TMPDIR/etc/avahi"
  mkdir -p "$host_systemd_path" "$host_logrotated_path" "$host_cron_path" "$host_avahi_path"
  ln -s "$ROOT/current/config/cron/mgw_abc_update" "$host_cron_path/mgw_abc_update"
  ln -s "$ROOT/current/config/avahi/mgw_abc_core.service" "$host_avahi_path/mgw_abc_core.service"
  ln -s "/elsewhere/current/config/cron/x" "$host_cron_path/other"
  echo plain > "$host_logrotated_path/mgw_abc_core"
  run objects 'objectsRemove "$ROOT" etclinks:'
  [ "$status" -eq 0 ]
  [ ! -L "$host_cron_path/mgw_abc_update" ] && [ ! -L "$host_avahi_path/mgw_abc_core.service" ]
  [ -L "$host_cron_path/other" ] && [ -f "$host_logrotated_path/mgw_abc_core" ]
}
