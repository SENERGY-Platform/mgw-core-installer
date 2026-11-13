#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# setup.sh end to end on the test VM, with the real host binaries and images: it downloads about
# 130 MiB per install, so the file takes a while. The tests run in order and share one install
# directory: core A (config file, systemd) and core B (interactive, without systemd) are installed
# next to each other, then the collision checks, failures, a killed install and recover.sh run
# against them. Everything is removed in teardown_file; the pulled images are kept.

load ../unit/helpers
load github

# Subnets and ports: each file has ranges of its own, so files can run in parallel (tests/vm/run.sh
# -j): core and gateway 10.<n>.0.0 and 10.<n>.1.0, module 10.<n+120>.0.0/16, with n in steps of ten
# per file (setup 20, uninstall 35, ctrl 45, update 55, update_failures 65, recover 75, version 85,
# restore 95, migration 105, migration_success 115, migration_nosystemd 125, migration_interrupted
# 130, update_archive 15; n = 0, 1 and 10 stay free: the default subnets of a core installed by
# hand);
# gateway ports per file in thousands from 20000. Only 10.x: docker uses 172.17.0.0/16 and up.

setup_file() {
  startGithubMock
  export REPO="$BATS_TEST_DIRNAME/../.."
  export DIR="/var/tmp/mgwt-install-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  export A="a$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')" B="b$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  local n=$((RANDOM % 5 + 20))
  export NA="$n" NB="$((n + 1))" PA="$((20000 + RANDOM % 900))"
  export PB="$((PA + 1))"
}

teardown_file() {
  stopGithubMock
  local root unit
  for root in "$DIR"/*; do
    [ -d "$root/state" ] || continue
    for unit in /etc/systemd/system/mgw_"${root##*/}"-*.service; do
      [ -e "$unit" ] && systemctl stop "${unit##*/}" > /dev/null 2>&1
    done
    teardownCore "$root"
  done
  rm -rf "$DIR"
}

# removes the core at $1 by its install record, keeping the images for the next run
teardownCore() {
  [ -d "$1/state" ] || return 0
  rm -f "$1/state/images"
  dsh 'settingsLoad "'"$1"'/current/assets/settings.defaults" "'"$1"'/state/settings" 2> /dev/null
    if [ -e "'"$1"'/state/pid" ]; then coreStopBins "'"$1"'"; fi
    installCleanup "'"$1"'" "'"$1"'/state/install"' file settings state lock host objects core > /dev/null 2>&1 || true
  pkill -KILL -f "^$1/" 2> /dev/null || true
  rm -rf "$1"
}

# writes a config file for the core id $1, port $2, subnet number $3 and the further lines after $3
conf() {
  local id="$1" port="$2" n="$3"
  shift 3
  printf '%s\n' "install_dir=$DIR" "core_id=$id" "gateway_port=$port" "subnet_core=10.$n.0.0" "subnet_gateway=10.$n.1.0" \
    "subnet_module=10.$((n + 120)).0.0" logrotate=false cron=false advertise=false "$@" > "$BATS_TEST_TMPDIR/$id.conf"
  echo "$BATS_TEST_TMPDIR/$id.conf"
}

# waits up to 6 minutes until every long-running container of the core $1 runs and its one-shot
# services completed successfully
waitForContainers() {
  local project="mgw_$1_$(cd "$DIR/$1" && readlink current)" i=0 states
  while [ $i -lt 72 ]; do
    states="$(docker ps -a --filter "label=com.docker.compose.project=$project" --format '{{.Label "core_srv_oneshot"}} {{.State}} {{.Status}}')"
    if [ "$(echo "$states" | grep -c .)" -eq 9 ] && ! echo "$states" | grep -v '^true exited Exited (0)' | grep -qv ' running '; then
      return 0
    fi
    sleep 5
    i=$((i + 1))
  done
  echo "$states"
  return 1
}

@test "core A: config file, systemd, started: the core comes up" {
  run "$REPO/setup.sh" -c "$(conf "$A" "$PA" "$NA" autostart=true start_core=true)"
  echo "$output"
  [ "$status" -eq 0 ]
  local root="$DIR/$A"
  grep -qx result=success "$root/state/install"
  [[ "$(readlink "$root/current")" == dev-* ]]
  [[ "$output" == *"password: core_usr_pw in $root/state/settings"* ]]
  # pinned settings, generated passwords
  grep -qx "gateway_port=$PA" "$root/state/settings" && grep -qx "stack_name=mgw_$A" "$root/state/settings"
  [ "$(grep '^core_db_pw=' "$root/state/settings" | cut -d= -f2 | wc -c)" -eq 33 ]
  [ "$(stat -c %a "$root/state/settings")" = "600" ]
  for unit in ce-wrapper host-manager core-manager; do
    [ "$(systemctl is-active "mgw_$A-$unit.service")" = "active" ]
  done
  [ "$(systemctl is-active "mgw_$A-recover.service")" = "active" ]
  [ "$(systemctl is-enabled "mgw_$A-recover.service")" = "enabled" ]
  [ "$(findmnt -n -o FSTYPE "/mnt/mgw_$A/secrets")" = "tmpfs" ]
  [ "$(systemctl is-active "$(systemd-escape --path --suffix=mount "/mnt/mgw_$A/secrets")")" = "active" ]
  waitForContainers "$A"
  # the install's log, from the moment the core root exists
  grep -Eq '^[0-9T:-]+Z setup\.sh\[[0-9]+\]: installation of dev-[0-9]+ successful' "$root/log/scripts.log"
}

@test "core B: interactive, without systemd, in the same install directory" {
  answers=(y y "$DIR" "$B" "" "" "" "$PB" "10.$NB.0.0" "10.$((NB + 120)).0.0" "10.$NB.1.0" "" n n n n n y)
  run sh -c "printf '%s\n' \"\$@\" | '$REPO/setup.sh'" sh "${answers[@]}"
  echo "$output"
  [ "$status" -eq 0 ]
  local root="$DIR/$B"
  grep -qx result=success "$root/state/install"
  grep -qx autostart=false "$root/state/settings"
  [[ "$output" == *"password: "[0-9a-f]* ]]
  # the password is shown, but never logged
  grep -q " setup\.sh\[[0-9]*\]: installation of " "$root/log/scripts.log"
  ! grep -qF "$(grep '^core_usr_pw=' "$root/state/settings" | cut -d= -f2)" "$root/log/scripts.log"
  [ "$(wc -l < "$root/state/pid")" -eq 3 ]
  [ "$(findmnt -n -o FSTYPE "/mnt/mgw_$B/secrets")" = "tmpfs" ]
  [ -z "$(find /etc/systemd/system -name "mgw_$B-*")" ]
  waitForContainers "$B"
  # both cores
  [ -d "$DIR/$A/current" ] && [ -d "$DIR/$B/current" ]
}

@test "collisions are refused before anything changes" {
  # the same core id
  run "$REPO/setup.sh" -c "$(conf "$A" "$((PB + 1))" "$((NB + 1))")"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$DIR/$A exists"* ]] && [[ "$output" == *"restore.sh"* ]]
  # core A's port and subnets, with a fresh core id
  run "$REPO/setup.sh" -c "$(conf c1 "$PA" "$NA")"
  [ "$status" -eq 1 ]
  [[ "$output" == *"port $PA is in use"* ]]
  [[ "$output" == *"subnet 10.$NA.0.0/28 overlaps"* ]]
  [ ! -e "$DIR/c1" ]
  grep -qx result=success "$DIR/$A/state/install"
}

@test "invalid settings are refused before anything changes" {
  run "$REPO/setup.sh" -c "$(conf c2 0 "$((NB + 2))")"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid gateway_port '0'"* ]]
  printf '%s\n' 'base_path=/opt/mgw' > "$BATS_TEST_TMPDIR/old.conf"
  run "$REPO/setup.sh" -c "$BATS_TEST_TMPDIR/old.conf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a known setting"* ]]
  [ ! -e "$DIR/c2" ]
}

@test "a failure removes everything the install created" {
  run env MGW_TEST_FAIL_AT=folders "$REPO/setup.sh" -c "$(conf c3 "$((PB + 3))" "$((NB + 3))")"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"removing what the install created"* ]]
  [ ! -e "$DIR/c3" ]
}

@test "a failure after prepare removes the version, containers, volumes, networks, units and tmpfs" {
  run env MGW_TEST_FAIL_AT=activate "$REPO/setup.sh" -c "$(conf c4 "$((PB + 4))" "$((NB + 4))" autostart=true)"
  echo "$output"
  [ "$status" -eq 1 ]
  [ ! -e "$DIR/c4" ] && [ ! -e /mnt/mgw_c4 ]
  [ -z "$(docker ps -aq --filter "label=mgw_cid=c4")" ]
  [ -z "$(docker volume ls -q | grep '^mgw_c4_')" ]
  [ -z "$(docker network ls --format '{{.Name}}' | grep '^mgw_c4-')" ]
  [ -z "$(find /etc/systemd/system -name 'mgw_c4-*' -o -name 'mnt-mgw_c4-*')" ]
  # the images other cores use are still there
  docker image inspect "$(docker inspect -f '{{.Config.Image}}' "mgw_$A-$(readlink "$DIR/$A/current")-nginx")" > /dev/null
}

@test "a killed install is found and removed by the next setup.sh" {
  setsid "$REPO/setup.sh" -c "$(conf c5 "$((PB + 5))" "$((NB + 5))")" > "$BATS_TEST_TMPDIR/c5.log" 2>&1 &
  local pid=$! i=0
  until grep -q '^created=folder:dev-.*_tmp$' "$DIR/c5/state/install" 2> /dev/null; do
    sleep 0.5; i=$((i + 1))
    if [ $i -ge 120 ]; then cat "$BATS_TEST_TMPDIR/c5.log"; false; fi
  done
  kill -KILL -- "-$pid"
  wait "$pid" 2> /dev/null || true
  grep -qx result=running "$DIR/c5/state/install"
  run "$REPO/setup.sh" -c "$(conf c6 "$((PB + 6))" "$((NB + 6))")"
  [[ "$output" == *"unfinished install found: $DIR/c5"* ]]
  [ ! -e "$DIR/c5" ]
  teardownCore "$DIR/c6"
}

@test "recover.sh leaves a core alone while its lock is held, and removes an unfinished install" {
  local root="$DIR/$B"
  coreStop() { :; }
  dsh 'settingsLoad "'"$root"'/current/assets/settings.defaults" "'"$root"'/state/settings"; coreStopBins "'"$root"'"' file settings state host core > /dev/null
  sed -i 's/^result=success$/result=running/' "$root/state/install"
  exec 7<> "$root/state/lock"
  flock 7
  run "$root/current/assets/scripts/recover.sh"
  exec 7>&-
  [ "$status" -eq 0 ]
  [[ "$output" == *"the lock is held"* ]]
  [ -d "$root" ]
  run "$root/current/assets/scripts/recover.sh"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unfinished install found"* ]]
  [ ! -e "$root" ] && [ ! -e "/mnt/mgw_$B" ]
  [ -z "$(docker ps -aq --filter "label=mgw_cid=$B")" ]
}
