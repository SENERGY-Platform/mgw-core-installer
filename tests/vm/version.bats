#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# Prepare and activate a version with the real tools on the test VM: the host binaries are downloaded
# from GitHub, the images pulled from their registries. Needs internet access.
#
# The host binaries' release archives are large (about 130 MiB for the three), so the file prepares
# one version in setup_file, and its first three tests run in order on it: inspect, activate, clean
# up. The other tests don't need a real prepare and use folders of their own.

load ../unit/helpers
load github

setup_file() {
  startGithubMock
  export ASSETS="$BATS_TEST_DIRNAME/../../assets"
  export CORE="mgwt$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  export ROOT="/var/tmp/$CORE" R="/var/tmp/$CORE/state/install"
  export host_logrotated_path="$BATS_FILE_TMPDIR" host_cron_path="$BATS_FILE_TMPDIR" host_avahi_path="$BATS_FILE_TMPDIR"
  mkdir -p "$ROOT/state"
  # subnets of their own, so the test can't collide with the networks of a core on the VM
  local n=$((RANDOM % 200 + 20))
  printf '%s\n' "core_id=${CORE#mgwt}" "core_name=$CORE" "stack_name=$CORE" "host_dir_repository_path=$ROOT/repositories/host_dir" \
    core_usr_pw=userpassword core_db_pw=dbpassword core_db_root_pw=rootpassword \
    "subnet_core=10.$n.0.0" "subnet_gateway=10.$n.1.0" "subnet_module=172.$((n % 16 + 16)).0.0" \
    systemd=true logrotate=false cron=false advertise=false > "$ROOT/state/settings"
  version '
    installRecordBegin "$R" v0_40_0 install
    objects_record="$R"
    installRecordAdd "$R" folder:.
    versionPrepare "$ROOT" "$ASSETS" v0.40.0 0 0' > "$BATS_FILE_TMPDIR/prepare.log" 2>&1
  echo $? > "$BATS_FILE_TMPDIR/prepare.rc"
}

teardown_file() {
  stopGithubMock
  docker ps -aq --filter "label=com.docker.compose.project=${CORE}_v0_40_0" | xargs -r docker rm -f > /dev/null
  docker volume ls -q --filter "name=$CORE" | xargs -r docker volume rm > /dev/null
  docker network ls -q --filter "name=$CORE" | xargs -r docker network rm > /dev/null
  version 'objectsRemove "$ROOT" etclinks:' > /dev/null 2>&1 || true
  systemctl daemon-reload
  rm -rf "$ROOT"
}

version() {
  dsh 'net_retry_delays="5"; settingsLoad "$ASSETS/settings.defaults" "$ROOT/state/settings" || exit 9; '"$1" \
    file settings state host render reconcile net docker objects core version
}

@test "prepare builds the version folder up to the created containers, recording everything" {
  cat "$BATS_FILE_TMPDIR/prepare.log"
  [ "$(cat "$BATS_FILE_TMPDIR/prepare.rc")" -eq 0 ]
  local v="$ROOT/v0_40_0"
  [ -d "$v/assets/templates" ] && [ ! -e "$ROOT/v0_40_0_tmp" ] && [ ! -e "$v/.download" ]
  [ "$(cat "$v/assets/version")" = "v0.40.0" ]
  [ "$(readlink "$v/update.sh")" = "assets/scripts/update.sh" ]
  [ "$(readlink "$v/uninstall.sh")" = "assets/scripts/uninstall.sh" ]
  for repo in mgw-container-engine-wrapper mgw-host-manager mgw-core-manager; do
    [ -x "$v/bin/SENERGY-Platform/$repo/bin" ]
    file "$v/bin/SENERGY-Platform/$repo/bin" | grep -q "ELF 64-bit.*x86-64"
  done
  grep -q '"compose_file_path": "'"$ROOT"'/current/config/container/docker-compose.yml"' \
    "$v/config/host-binaries/SENERGY-Platform/mgw-core-manager/conf.json"
  # core-owned docker objects, labelled
  [ "$(docker network inspect -f '{{index .Labels "mgw_cid"}}' "$CORE-2-module-net")" = "${CORE#mgwt}" ]
  [ "$(docker volume inspect -f '{{index .Labels "mgw_cid"}}' "${CORE}_mysqldb-data")" = "${CORE#mgwt}" ]
  # the containers exist, none started, all with the version in their names
  [ "$(docker ps -a --filter "label=com.docker.compose.project=${CORE}_v0_40_0" --format '{{.State}}' | sort -u)" = "created" ]
  [ "$(docker ps -aq --filter "label=com.docker.compose.project=${CORE}_v0_40_0" | wc -l)" -eq 9 ]
  docker inspect "$CORE-v0_40_0-nginx" > /dev/null
  # everything recorded
  grep -qx "created=folder:v0_40_0_tmp" "$R" && grep -qx "created=folder:v0_40_0" "$R"
  grep -qx "created=network:$CORE-1-core-net" "$R" && grep -qx "created=volume:${CORE}_sm-data" "$R"
  grep -qx "created=project:${CORE}_v0_40_0" "$R"
  [ "$(wc -l < "$ROOT/state/images")" -eq 8 ]
}

@test "activate points current at the version and links the units" {
  run version 'objects_record="$R"; versionActivate "$ROOT" v0_40_0'
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(readlink "$ROOT/current")" = "v0_40_0" ]
  [ -z "$(find "$ROOT" -maxdepth 1 -name '.current.*')" ]
  [ "$(systemctl is-enabled "$CORE-core-manager.service")" = "enabled" ]
  [ "$(systemctl show -p ExecStart --value "$CORE-core-manager.service" | grep -o "path=[^ ;]*")" = "path=$ROOT/current/bin/SENERGY-Platform/mgw-core-manager/bin" ]
  grep -qx "created=link:current" "$R" && grep -qx "created=etclinks:" "$R"
}

@test "the cleanup removes everything prepare and activate created" {
  run version 'installCleanup "$ROOT" "$R"'
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT" ]
  [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=${CORE}_v0_40_0")" ]
  [ -z "$(docker volume ls -q --filter "name=$CORE")" ]
  [ -z "$(docker network ls -q --filter "name=$CORE")" ]
  [ ! -e "/etc/systemd/system/$CORE-core-manager.service" ]
  [ -z "$(find /etc/systemd/system -name "$CORE-*")" ]
}

@test "prepare refuses an existing version folder and removes a leftover _tmp folder" {
  local root="/var/tmp/${CORE}x"
  mkdir -p "$root/state" "$root/v0_40_0_tmp/leftover" "$root/v0_41_0"
  run dsh 'versionPrepare "'"$root"'" "$ASSETS" v0.41.0 0 0' file settings state host render reconcile net docker objects core version
  [ "$status" -eq 1 ]
  [[ "$output" == *"exists already"* ]]
  run dsh 'settingsLoad "$ASSETS/settings.defaults" "" ; versionDownloadBins() { return 9; }; renderVersion() { return 0; }
    versionPrepare "'"$root"'" "$ASSETS" v0.40.0 0 0' file settings state host render reconcile net docker objects core version
  [ "$status" -eq 9 ]
  [ ! -e "$root/v0_40_0_tmp/leftover" ]
  rm -rf "$root"
}

@test "activate switches an existing current without a gap and refuses a missing folder" {
  local root="/var/tmp/${CORE}y"
  mkdir -p "$root/v1/config" "$root/v2/config"
  ln -s v1 "$root/current"
  run dsh 'versionActivate "'"$root"'" v2' file settings state host render reconcile net docker objects core version
  [ "$status" -eq 0 ]
  [ "$(readlink "$root/current")" = "v2" ]
  run dsh 'versionActivate "'"$root"'" missing' file settings state host render reconcile net docker objects core version
  [ "$status" -eq 1 ]
  [ "$(readlink "$root/current")" = "v2" ]
  rm -rf "$root"
}
