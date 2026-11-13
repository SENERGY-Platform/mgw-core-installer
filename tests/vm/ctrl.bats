#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# ctrl.sh on the test VM, against two cores installed with setup.sh (GitHub mock, real images): X with
# autostart (systemd services), Y without (detached processes). The tests run in order.

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
  export DIR="/var/tmp/mgwt-ctrl-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  export X="x$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')" Y="y$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  local n=$((RANDOM % 8 + 45)) id auto
  for id in "$X" "$Y"; do
    auto=true
    [ "$id" = "$Y" ] && auto=false
    printf '%s\n' "install_dir=$DIR" "core_id=$id" "gateway_port=$((22000 + RANDOM % 500))" "subnet_core=10.$n.0.0" \
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
  # start is logged, status isn't
  grep -q " ctrl\.sh\[[0-9]*\]: starting " "$DIR/$X/log/scripts.log"
  ! grep -q "running:     running" "$DIR/$X/log/scripts.log"
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

@test "ctr-recreate on a stopped core: new containers, still stopped" {
  local before
  before="$(docker ps -aq --filter "label=mgw_cid=$X" | sort)"
  run "$DIR/$X/current/ctrl.sh" ctr-recreate
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(docker ps -aq --filter "label=mgw_cid=$X" | wc -l)" -eq 9 ]
  [ -z "$(comm -12 <(echo "$before") <(docker ps -aq --filter "label=mgw_cid=$X" | sort))" ]
  waitForRunning "$X" 0
  [ "$(systemctl is-active "mgw_$X-core-manager.service")" = "inactive" ]
}

@test "ctr-recreate on a running core: new containers, the core runs again, migrations done" {
  "$DIR/$Y/current/ctrl.sh" start > /dev/null
  waitForRunning "$Y" 7
  local before
  before="$(docker ps -aq --filter "label=mgw_cid=$Y" | sort)"
  run "$DIR/$Y/current/ctrl.sh" ctr-recreate
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$(comm -12 <(echo "$before") <(docker ps -aq --filter "label=mgw_cid=$Y" | sort))" ]
  [ "$(wc -l < "$DIR/$Y/state/pid")" -eq 3 ]
  waitForRunning "$Y" 7
  [ "$(docker ps -a --filter "label=mgw_cid=$Y" --filter label=core_srv_oneshot=true --format '{{.Status}}' | grep -c '^Exited (0)')" -eq 2 ]
  "$DIR/$Y/current/ctrl.sh" stop > /dev/null
}

@test "help and unknown commands" {
  run "$DIR/$X/current/ctrl.sh" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"restart"* ]] && [[ "$output" != *"enable"* ]]
  run "$DIR/$X/current/ctrl.sh" ctr-purge
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown command 'ctr-purge'"* ]]
}

@test "settings: list and get" {
  run "$DIR/$X/current/ctrl.sh" settings list
  [ "$status" -eq 0 ]
  [[ "$output" == *"core_id=$X (set)"* ]]
  [[ "$output" == *"core_db_pw=(hidden) (set)"* ]]
  [[ "$output" == *"kratos_log_level=warning"* ]]
  run "$DIR/$X/current/ctrl.sh" settings get core_name
  [ "$output" = "mgw_$X" ]
  run "$DIR/$X/current/ctrl.sh" settings get no_such_key
  [ "$status" -eq 1 ]
}

@test "settings: refused, unknown and invalid" {
  run "$DIR/$X/current/ctrl.sh" settings set core_id other
  [ "$status" -eq 1 ] && [[ "$output" == *"core_id can't be changed: it is the core's identity"* ]]
  run "$DIR/$X/current/ctrl.sh" settings set subnet_core 10.99.0.0
  [ "$status" -eq 1 ] && [[ "$output" == *"docker networks"* ]]
  run "$DIR/$X/current/ctrl.sh" settings set no_such_key x
  [ "$status" -eq 1 ] && [[ "$output" == *"unknown setting"* ]]
  run "$DIR/$X/current/ctrl.sh" settings set gateway_port 0
  [ "$status" -eq 1 ] && [[ "$output" == *"invalid gateway_port"* ]]
  run "$DIR/$X/current/ctrl.sh" settings set gateway_port 22
  [ "$status" -eq 1 ] && [[ "$output" == *"port 22 is in use"* ]]
  run "$DIR/$X/current/ctrl.sh" settings reset gateway_port
  [ "$status" -eq 1 ] && [[ "$output" == *"can't be reset"* ]]
}

@test "settings: a stored-only setting, and a failed render keeps the old value" {
  run "$DIR/$X/current/ctrl.sh" settings set allow_beta true
  [ "$status" -eq 0 ]
  grep -qx allow_beta=true "$DIR/$X/state/settings"
  run env MGW_TEST_FAIL_AT=render "$DIR/$X/current/ctrl.sh" settings set allow_beta false
  [ "$status" -eq 1 ]
  [[ "$output" == *"allow_beta stays true"* ]]
  grep -qx allow_beta=true "$DIR/$X/state/settings"
  run "$DIR/$X/current/ctrl.sh" settings reset allow_beta
  [ "$status" -eq 0 ]
  ! grep -q '^allow_beta=' "$DIR/$X/state/settings"
}

@test "settings: a log level recreates the containers of a running core" {
  "$DIR/$Y/current/ctrl.sh" start > /dev/null
  waitForRunning "$Y" 7
  run "$DIR/$Y/current/ctrl.sh" settings set kratos_log_level debug
  echo "$output"
  [ "$status" -eq 0 ]
  waitForRunning "$Y" 7
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "mgw_$Y-$(readlink "$DIR/$Y/current")-kratos" | grep -qx LOG_LEVEL=debug
  run "$DIR/$Y/current/ctrl.sh" settings reset kratos_log_level
  [ "$status" -eq 0 ]
  waitForRunning "$Y" 7
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "mgw_$Y-$(readlink "$DIR/$Y/current")-kratos" | grep -qx LOG_LEVEL=warning
}

@test "settings: the gateway port moves nginx" {
  local port=$((22500 + RANDOM % 500))
  run "$DIR/$Y/current/ctrl.sh" settings set gateway_port "$port"
  echo "$output"
  [ "$status" -eq 0 ]
  waitForRunning "$Y" 7
  docker port "mgw_$Y-$(readlink "$DIR/$Y/current")-nginx" | grep -q ":$port\$"
  "$DIR/$Y/current/ctrl.sh" stop > /dev/null
}

@test "settings: an integration is linked and unlinked" {
  run "$DIR/$X/current/ctrl.sh" settings set logrotate true
  echo "$output"
  [ "$status" -eq 0 ]
  [ -L "/etc/logrotate.d/mgw_${X}_core" ]
  logrotate -d "/etc/logrotate.d/mgw_${X}_core" > /dev/null 2>&1
  run "$DIR/$X/current/ctrl.sh" settings set logrotate false
  [ "$status" -eq 0 ]
  [ ! -e "/etc/logrotate.d/mgw_${X}_core" ]
}

@test "settings: secrets_size rewrites the mount unit, the tmpfs keeps its size until a reboot" {
  local unit before
  unit="/etc/systemd/system/$(systemd-escape --path --suffix=mount "/mnt/mgw_$X/secrets")"
  before="$(df -h --output=size "/mnt/mgw_$X/secrets" | tail -1 | tr -d ' ')"
  run "$DIR/$X/current/ctrl.sh" settings set secrets_size 200M
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"takes effect at the next reboot"* ]]
  grep -q 'size=200M' "$unit"
  [ "$(df -h --output=size "/mnt/mgw_$X/secrets" | tail -1 | tr -d ' ')" = "$before" ]
  run "$DIR/$X/current/ctrl.sh" status
  [[ "$output" == *"secrets:     $before mounted, 200M configured"* ]]
}

@test "settings: a confirmation without a terminal and without -y is refused" {
  run "$DIR/$X/current/ctrl.sh" settings set autostart false < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"confirmation needed, run with -y"* ]]
  grep -qx autostart=true "$DIR/$X/state/settings"
}

@test "settings: autostart off and on again, the tmpfs and its secrets stay" {
  local mount_unit
  mount_unit="$(systemd-escape --path --suffix=mount "/mnt/mgw_$X/secrets")"
  "$DIR/$X/current/ctrl.sh" start > /dev/null
  waitForRunning "$X" 7
  echo secret > "/mnt/mgw_$X/secrets/marker"
  run "$DIR/$X/current/ctrl.sh" -y settings set autostart false
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$(find /etc/systemd/system -name "mgw_$X-*" -o -name "$mount_unit")" ]
  [ "$(wc -l < "$DIR/$X/state/pid")" -eq 3 ]
  [ "$(cat "/mnt/mgw_$X/secrets/marker")" = "secret" ]
  waitForRunning "$X" 7
  run "$DIR/$X/current/ctrl.sh" -y settings set autostart true
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(systemctl is-active "mgw_$X-core-manager.service")" = "active" ]
  [ "$(systemctl is-active "$mount_unit")" = "active" ]
  [ "$(systemctl is-enabled "mgw_$X-recover.service")" = "enabled" ]
  [ ! -e "$DIR/$X/state/pid" ]
  [ "$(cat "/mnt/mgw_$X/secrets/marker")" = "secret" ]
  waitForRunning "$X" 7
  "$DIR/$X/current/ctrl.sh" stop > /dev/null
}
