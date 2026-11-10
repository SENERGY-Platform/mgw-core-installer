#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# ctrl.sh on the test VM, against two cores installed with setup.sh (GitHub mock, real images): X with
# autostart (systemd services), Y without (detached processes). The tests run in order.

load ../unit/helpers
load github

# Subnets: only 10.x ranges, docker uses 172.17.0.0/16 and up for its own networks.

setup_file() {
  startGithubMock
  export REPO="$BATS_TEST_DIRNAME/../.."
  export DIR="/var/tmp/mgwt-ctrl-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  export X="x$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')" Y="y$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  local n=$((RANDOM % 90 + 20)) id auto
  for id in "$X" "$Y"; do
    auto=true
    [ "$id" = "$Y" ] && auto=false
    printf '%s\n' "install_dir=$DIR" "core_id=$id" "gateway_port=$((20000 + RANDOM % 10000))" "subnet_core=10.$n.0.0" \
      "subnet_gateway=10.$n.1.0" "subnet_module=10.$((n + 120)).0.0" "autostart=$auto" start_core=false \
      logrotate=false cron=false advertise=false > "$BATS_FILE_TMPDIR/$id.conf"
    "$REPO/setup.sh" -c "$BATS_FILE_TMPDIR/$id.conf" > "$BATS_FILE_TMPDIR/$id.log" 2>&1
    n=$((n + 1))
  done
}

teardown_file() {
  stopGithubMock
  local root
  for root in "$DIR"/*; do
    [ -d "$root/state" ] || continue
    rm -f "$root/state/images"
    "$root/current/uninstall.sh" -y > /dev/null 2>&1 || true
  done
  rm -rf "$DIR"
}

# waits up to 5 minutes until $2 of the core $1's long-running containers are running
waitForRunning() {
  local i=0 n
  while [ $i -lt 60 ]; do
    # grep -c prints 0 but fails without a match, which would end the test under set -e
    n="$(docker ps --filter "label=mgw_cid=$1" --filter status=running --format '{{.Label "core_srv_oneshot"}}' | grep -c '^$' || true)"
    [ "$n" -eq "$2" ] && return 0
    sleep 5
    i=$((i + 1))
  done
  docker ps -a --filter "label=mgw_cid=$1" --format '{{.Names}} {{.Status}}'
  return 1
}

@test "both cores are installed, not started" {
  grep -qx result=success "$DIR/$X/state/install"
  grep -qx result=success "$DIR/$Y/state/install"
  run "$DIR/$X/current/ctrl.sh" status
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"running:     stopped"* ]]
  [[ "$output" == *"containers:  0 of 7 running"* ]]
  [[ "$output" == *"autostart:   true"* ]]
}

@test "with autostart: start starts the services, the core-manager the containers" {
  run "$DIR/$X/current/ctrl.sh" start
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(systemctl is-active "mgw_$X-core-manager.service")" = "active" ]
  waitForRunning "$X" 7
  run "$DIR/$X/current/ctrl.sh" status
  [[ "$output" == *"running:     running"* ]]
  [[ "$output" == *"containers:  7 of 7 running"* ]]
}

@test "with autostart: restart brings the core back" {
  local before
  before="$(systemctl show -p MainPID --value "mgw_$X-core-manager.service")"
  run "$DIR/$X/current/ctrl.sh" restart
  [ "$status" -eq 0 ]
  [ "$(systemctl show -p MainPID --value "mgw_$X-core-manager.service")" != "$before" ]
  waitForRunning "$X" 7
}

@test "a held lock refuses changing commands; status names the holder" {
  printf '%s\n' holder=update pid=4711 since=2026-11-10T03:00:00Z > "$DIR/$X/state/lock"
  exec 7<> "$DIR/$X/state/lock"
  flock 7
  run "$DIR/$X/current/ctrl.sh" stop
  local stop_rc="$status" stop_out="$output"
  run "$DIR/$X/current/ctrl.sh" status
  exec 7>&-
  [ "$stop_rc" -eq 1 ]
  [[ "$stop_out" == *"locked by update (pid 4711) since 2026-11-10T03:00:00Z, giving up"* ]]
  [ "$status" -eq 0 ]
  [[ "$output" == *"lock:        locked by update (pid 4711)"* ]]
  [ "$(systemctl is-active "mgw_$X-core-manager.service")" = "active" ]
}

@test "with autostart: stop stops the services and the containers, the tmpfs stays" {
  run "$DIR/$X/current/ctrl.sh" stop
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(systemctl is-active "mgw_$X-core-manager.service")" = "inactive" ]
  waitForRunning "$X" 0
  [ "$(findmnt -n -o FSTYPE "/mnt/mgw_$X/secrets")" = "tmpfs" ]
}

@test "an interrupted update refuses start, allows stop, and status points to restore.sh" {
  printf '%s\n' result=running from_version=v1 to_version=v2 phase=switching > "$DIR/$X/state/update"
  run "$DIR/$X/current/ctrl.sh" start
  [ "$status" -eq 1 ]
  [[ "$output" == *"the core needs repair: an update was interrupted (from v1 to v2, phase switching)"* ]]
  [[ "$output" == *"run $DIR/$X/current/restore.sh; ctrl.sh start is refused until then"* ]]
  [ "$(systemctl is-active "mgw_$X-core-manager.service")" = "inactive" ]
  run "$DIR/$X/current/ctrl.sh" stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"note: the core needs repair"* ]]
  run "$DIR/$X/current/ctrl.sh" status
  [[ "$output" == *"the core needs repair"* ]]
  printf '%s\n' result=failed interrupted=true recovery_failed=true > "$DIR/$X/state/update"
  run "$DIR/$X/current/ctrl.sh" restart
  [ "$status" -eq 1 ]
  [[ "$output" == *"the recovery of an interrupted update failed"* ]]
  rm "$DIR/$X/state/update"
}

@test "without autostart: start runs the host binaries detached, the containers come up" {
  run "$DIR/$Y/current/ctrl.sh" start
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$DIR/$Y/state/pid")" -eq 3 ]
  waitForRunning "$Y" 7
  run "$DIR/$Y/current/ctrl.sh" status
  [[ "$output" == *"running:     running"* ]]
  [[ "$output" == *"autostart:   false"* ]]
}

@test "without autostart: stop ends the host binaries and the containers" {
  run "$DIR/$Y/current/ctrl.sh" stop
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$DIR/$Y/state/pid" ]
  waitForRunning "$Y" 0
  [ "$(findmnt -n -o FSTYPE "/mnt/mgw_$Y/secrets")" = "tmpfs" ]
}

@test "help and unknown commands" {
  run "$DIR/$X/current/ctrl.sh" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"restart"* ]] && [[ "$output" != *"enable"* ]]
  run "$DIR/$X/current/ctrl.sh" ctr-purge
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown command 'ctr-purge'"* ]]
}
