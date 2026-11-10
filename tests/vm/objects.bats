#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# Creating and removing a core's docker objects, units and mounts with the real tools on the test VM.
# Each test uses its own names and removes everything it created.

load ../unit/helpers

setup() {
  export CORE="mgwt$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  export ROOT="/var/tmp/$CORE" R="/var/tmp/$CORE/state/install"
  mkdir -p "$ROOT/state"
  printf '%s\n' 'core_name=' > "$BATS_TEST_TMPDIR/defaults"
}

teardown() {
  docker ps -aq --filter "label=com.docker.compose.project=$CORE" | xargs -r docker rm -f > /dev/null
  docker volume ls -q --filter "name=$CORE" | xargs -r docker volume rm > /dev/null
  docker network ls -q --filter "name=$CORE" | xargs -r docker network rm > /dev/null
  docker image rm "mgwtest/$CORE:1" > /dev/null 2>&1 || true
  local unit
  for unit in /etc/systemd/system/*"$CORE"*; do
    [ -e "$unit" ] || continue
    systemctl stop "${unit##*/}" > /dev/null 2>&1 || true
    systemctl disable "${unit##*/}" > /dev/null 2>&1 || true
    rm -f "$unit"
  done
  systemctl daemon-reload
  umount "/mnt/$CORE/secrets" 2> /dev/null || true
  rm -rf "$ROOT" "/mnt/$CORE"
}

objects() {
  dsh 'settingsLoad "$BATS_TEST_TMPDIR/defaults" "" || exit 9; '"$1" file settings state host objects
}

@test "a network is created with its subnet, attachable and labelled, once" {
  run objects '
    installRecordBegin "$R" v1_3_0 install
    objects_record="$R"
    objectsNetwork "$CORE-1-core-net" 10.231.0.0/28 abc
    objectsNetwork "$CORE-1-core-net" 10.231.0.0/28 abc'
  [ "$status" -eq 0 ]
  [ "$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}} {{.Attachable}} {{index .Labels "mgw_cid"}} {{.Driver}}' "$CORE-1-core-net")" = "10.231.0.0/28 true abc bridge" ]
  [ "$(grep -c "^created=network:$CORE-1-core-net$" "$R")" -eq 1 ]
}

@test "an existing volume is reused and not recorded" {
  docker volume create "${CORE}_data" > /dev/null
  run objects '
    installRecordBegin "$R" v1_3_0 install
    objects_record="$R"
    objectsVolume "${CORE}_data" abc
    objectsVolume "${CORE}_new" abc'
  [ "$status" -eq 0 ]
  ! grep -q "volume:${CORE}_data" "$R"
  grep -qx "created=volume:${CORE}_new" "$R"
  [ "$(docker volume inspect -f '{{index .Labels "mgw_cid"}}' "${CORE}_new")" = "abc" ]
}

@test "cleanup removes the containers before their volume and network" {
  run objects '
    installRecordBegin "$R" v1_3_0 install
    objects_record="$R"
    installRecordAdd "$R" folder:.
    objectsNetwork "$CORE-1-core-net" 10.232.0.0/28 abc
    objectsVolume "${CORE}_data" abc
    installRecordAdd "$R" "project:$CORE"
    docker create --label "com.docker.compose.project=$CORE" --network "$CORE-1-core-net" -v "${CORE}_data:/data" busybox:1.37 true > /dev/null
    installCleanup "$ROOT" "$R"'
  [ "$status" -eq 0 ]
  [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$CORE")" ]
  ! docker volume inspect "${CORE}_data" > /dev/null 2>&1
  ! docker network inspect "$CORE-1-core-net" > /dev/null 2>&1
  [ ! -e "$ROOT" ]
}

@test "cleanup stops and removes a core-owned mount unit, which unmounts the tmpfs" {
  mount_unit="$(systemd-escape --path --suffix=mount "/mnt/$CORE/secrets")"
  run objects '
    installRecordBegin "$R" v1_3_0 install
    objects_record="$R"
    installRecordAdd "$R" folder:.
    mkdir -p "/mnt/$CORE/secrets"
    printf "%s\n" "[Mount]" "What=tmpfs" "Where=/mnt/$CORE/secrets" "Type=tmpfs" "[Install]" "WantedBy=default.target" \
      | objectsFile "/etc/systemd/system/'"$mount_unit"'" 644
    systemctl daemon-reload
    installRecordAdd "$R" "unit:'"$mount_unit"'"
    systemctl enable --now "'"$mount_unit"'" 2> /dev/null
    findmnt -n "/mnt/$CORE/secrets" > /dev/null && echo mounted
    installCleanup "$ROOT" "$R"'
  [ "$status" -eq 0 ]
  [[ "$output" == *mounted* ]]
  ! findmnt -n "/mnt/$CORE/secrets" > /dev/null
  [ ! -e "/etc/systemd/system/$mount_unit" ]
  [ "$(systemctl is-enabled "$mount_unit" 2>&1)" != "enabled" ]
}

@test "cleanup unmounts a tmpfs mounted without systemd" {
  run objects '
    installRecordBegin "$R" v1_3_0 install
    objects_record="$R"
    mkdir -p "/mnt/$CORE/secrets"
    installRecordAdd "$R" "mount:/mnt/$CORE/secrets"
    mount -t tmpfs -o size=1M tmpfs "/mnt/$CORE/secrets"
    installCleanup "$ROOT" "$R"'
  [ "$status" -eq 0 ]
  ! findmnt -n "/mnt/$CORE/secrets" > /dev/null
}

@test "cleanup removes the pulled images nobody uses, keeps used ones listed" {
  docker tag busybox:1.37 "mgwtest/$CORE:1"
  printf '%s\n' "mgwtest/$CORE:1" busybox:1.37 > "$ROOT/state/images"
  docker create --name "$CORE-user" busybox:1.37 true > /dev/null
  run objects 'objectsRemoveImages "$ROOT/state/images"'
  docker rm -f "$CORE-user" > /dev/null
  ! docker image inspect "mgwtest/$CORE:1" > /dev/null 2>&1
  docker image inspect busybox:1.37 > /dev/null
  [ "$(cat "$ROOT/state/images")" = "busybox:1.37" ]
}
