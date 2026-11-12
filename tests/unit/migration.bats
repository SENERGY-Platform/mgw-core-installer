#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# lib/migration.sh: reading and checking an old installation (m7-migration.md, findings 3, 6, 7).

load helpers

setup() {
  export OLD="$BATS_TEST_TMPDIR/opt/mgw" DEFAULTS="$BATS_TEST_DIRNAME/../../assets/settings.defaults"
  mkdir -p "$OLD/container"
  # the .settings an old installer v0.30.0 to v0.33.0-beta2 writes (saveSettings)
  cat > "$OLD/.settings" <<EOF
base_path=$OLD
secrets_path=/mnt/mgw/secrets
deployments_path=$OLD/deployments
sockets_path=$OLD/sockets
host_dir_repository_path=$OLD/repositories/host_dir
bin_path=$OLD/bin
container_path=$OLD/container
log_path=$OLD/log
scripts_path=$OLD/scripts
mounts_path=$OLD/mounts
stack_name=mgw
subnet_core=10.0.0.0
subnet_module=10.1.0.0
subnet_gateway=10.10.0.0
core_db_pw=0123456789abcdef0123456789abcdef
core_db_root_pw=fedcba9876543210fedcba9876543210
systemd_path=/etc/systemd/system
logrotated_path=/etc/logrotate.d
avahi_path=/etc/avahi/services
cron_path=/etc/cron.daily
docker_socket_path=/var/run/docker.sock
systemd=true
ctr_restart_policy=unless-stopped
logrotate=true
cron=true
advertise=false
platform=linux
arch=amd64
core_id=1a2b3c4d
core_name=mgw
gateway_port=8080
allow_beta=false
core_usr=core-user
core_usr_pw=00112233445566778899aabbccddeeff
EOF
  cat > "$OLD/container/.env" <<'EOF'
AUTH_SERVICE_LOG_LEVEL=warning
MODULE_MANAGER_LOG_LEVEL=debug
MODULE_MANGER_HTTP_ACCESS_LOG=true
MODULE_MANAGER_DEP_STARTUP_DELAY=20s
MODULE_MANAGER_AUX_DEP_STARTUP_DELAY=30s
SECRET_MANAGER_LOG_LEVEL=warning
KRATOS_LOG_LEVEL=warning
KRATOS_MIGRATE_LOG_LEVEL=warning
EOF
}

mig() {
  dsh "settingsLoad \"\$DEFAULTS\" '' && $1" file settings state host semver setup migration
}

@test "the minimum version is v0.30.0-alpha1" {
  run mig 'migrationVersionOk v0.30.0-alpha1 && migrationVersionOk v0.30.0-beta5 && migrationVersionOk v0.33.0-beta2'
  [ "$status" -eq 0 ]
  run mig 'migrationVersionOk v0.23.0'
  [ "$status" -eq 1 ]
  [[ "$output" == *"older than v0.30.0-alpha1"* ]]
  run mig 'migrationVersionOk dev-1700000000'
  [ "$status" -eq 1 ]
  [[ "$output" == *"isn't a release"* ]]
}

@test "the .version of the installation" {
  echo v0.31.1 > "$OLD/.version"
  run mig 'migrationVersion "$OLD"'
  [ "$output" = "v0.31.1" ]
  rm "$OLD/.version"
  run mig 'migrationVersion "$OLD"'
  [ "$status" -eq 1 ]
}

@test "the old settings are parsed, not sourced; quotes are removed" {
  echo 'core_usr="$(touch $BATS_TEST_TMPDIR/sourced)"' >> "$OLD/.settings"
  echo "allow_beta='true'" >> "$OLD/.settings"
  run mig 'migrationReadOld "$OLD" && migrationOld core_usr && migrationOld allow_beta && migrationOld core_name'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '$(touch $BATS_TEST_TMPDIR/sourced)' ]
  [ "${lines[1]}" = "true" ]
  [ "${lines[2]}" = "mgw" ]
  [ ! -e "$BATS_TEST_TMPDIR/sourced" ]
}

@test "standard settings pass the check" {
  run mig 'migrationReadOld "$OLD" && migrationCheck "$OLD"'
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "a path that differs from the new layout stops the migration, every problem is named" {
  sed -i -e 's|^log_path=.*|log_path=/var/log/mgw|' -e 's|^cron_path=.*|cron_path=/etc/cron.hourly|' \
    -e 's|^secrets_path=.*|secrets_path=/mnt/other/secrets|' "$OLD/.settings"
  run mig 'migrationReadOld "$OLD" && migrationCheck "$OLD"'
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"log_path is '/var/log/mgw', the new layout needs $OLD/log"* ]]
  [[ "$output" == *"cron_path is '/etc/cron.hourly'"* ]]
  [[ "$output" == *"secrets_path is '/mnt/other/secrets', the new layout needs /mnt/mgw/secrets"* ]]
  [ "${#lines[@]}" -eq 3 ]
}

@test "a trailing slash on a path is no difference" {
  sed -i "s|^base_path=.*|base_path=$OLD/|" "$OLD/.settings"
  run mig 'migrationReadOld "$OLD" && migrationCheck "$OLD"'
  [ "$status" -eq 0 ]
}

@test "empty values the render needs, names the new layout can't use and an unknown systemd stop the migration" {
  sed -i -e 's|^core_db_pw=.*|core_db_pw=|' -e 's|^core_name=.*|core_name=Mgw.1|' -e 's|^systemd=.*|systemd=|' \
    -e "s|^secrets_path=.*|secrets_path=/mnt/Mgw.1/secrets|" "$OLD/.settings"
  run mig 'migrationReadOld "$OLD" && migrationCheck "$OLD"'
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"core_db_pw is empty"* ]]
  [[ "$output" == *"invalid core_name 'Mgw.1'"* ]]
  [[ "$output" == *"systemd is '', true or false is needed"* ]]
  [ "${#lines[@]}" -eq 3 ]
}

@test "other values are carried over unchecked: they work in the old layout" {
  sed -i -e 's|^core_usr_pw=.*|core_usr_pw=short!|' -e 's|^gateway_port=.*|gateway_port=99999|' \
    -e 's|^subnet_core=.*|subnet_core=10.0.0.5|' -e 's|^core_usr=.*|core_usr=a user|' "$OLD/.settings"
  run mig 'migrationReadOld "$OLD" && migrationCheck "$OLD" && migrationSettings "$OLD"'
  echo "$output"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'core_usr_pw=short!'
  printf '%s\n' "$output" | grep -qxF 'core_usr=a user'
}

@test "the new settings: carried over, systemd as autostart, the old tmpfs size, changed container values" {
  run mig 'migrationReadOld "$OLD" && migrationSettings "$OLD"'
  echo "$output"
  [ "$status" -eq 0 ]
  for kv in core_id=1a2b3c4d core_name=mgw stack_name=mgw "host_dir_repository_path=$OLD/repositories/host_dir" \
    gateway_port=8080 subnet_core=10.0.0.0 core_usr=core-user core_db_pw=0123456789abcdef0123456789abcdef \
    logrotate=true cron=true advertise=false allow_beta=false autostart=true secrets_size=100M \
    module_manager_log_level=debug module_manager_http_access_log=true; do
    printf '%s\n' "$output" | grep -qxF -- "$kv"
  done
  # unchanged container values keep floating with the defaults, dropped keys are gone
  ! printf '%s\n' "$output" | grep -q '^auth_service_log_level='
  ! printf '%s\n' "$output" | grep -q '^\(systemd\|base_path\|ctr_restart_policy\|platform\|systemd_path\)='
}

@test "an invalid container value is left out with a warning" {
  sed -i 's/^KRATOS_LOG_LEVEL=.*/KRATOS_LOG_LEVEL="debug"/' "$OLD/container/.env"
  run mig 'migrationReadOld "$OLD" && migrationSettings "$OLD" 2>&1'
  [[ "$output" == *"warning: KRATOS_LOG_LEVEL=\"debug\" in container/.env isn't a valid kratos_log_level"* ]]
  ! printf '%s\n' "$output" | grep -q '^kratos_log_level='
}

@test "no container/.env: only the settings" {
  rm "$OLD/container/.env"
  run mig 'migrationReadOld "$OLD" && migrationSettings "$OLD"'
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -q '_log_level='
}

@test "without systemd: running if a pid in .pid runs a binary of the installation" {
  sed -i 's/^systemd=.*/systemd=false/' "$OLD/.settings"
  mkdir -p "$OLD/bin/x"
  cp "$(command -v sleep)" "$OLD/bin/x/bin"
  run mig 'migrationReadOld "$OLD" && migrationWasRunning "$OLD"'
  [ "$status" -eq 1 ]
  sleep 30 &
  local other=$!
  echo "$other" > "$OLD/.pid"
  run mig 'migrationReadOld "$OLD" && migrationWasRunning "$OLD"'
  [ "$status" -eq 1 ]
  "$OLD/bin/x/bin" 30 &
  local ours=$!
  printf '99999999\n%s\n' "$ours" > "$OLD/.pid"
  run mig 'migrationReadOld "$OLD" && migrationWasRunning "$OLD"'
  kill "$other" "$ours"
  [ "$status" -eq 0 ]
}

@test "the old .update_status, readable by everyone" {
  run mig 'migrationOldStatus "$OLD" failed "the step" v0.31.1 v0.40.0 2026-11-11T03:00:00Z'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.result + "|" + .step + "|" + .from_version + "|" + .to_version + "|" + .started' "$OLD/.update_status")" = \
    "failed|the step|v0.31.1|v0.40.0|2026-11-11T03:00:00Z" ]
  [ "$(jq -r .finished "$OLD/.update_status")" != "" ]
  [ "$(stat -c %a "$OLD/.update_status")" = "644" ]
}

@test "the host-manager's data files and their backups are copied, the old ones stay" {
  local hm="$OLD/bin/SENERGY-Platform/mgw-host-manager" f
  mkdir -p "$hm/config"
  for f in applications.json applications.json.bk net_itf_blacklist.json net_itf_blacklist.json.bk \
    net_rng_blacklist.json net_rng_blacklist.json.bk; do
    echo "{\"file\":\"$f\"}" > "$hm/$f"
  done
  chmod 600 "$hm/applications.json"
  touch "$hm/bin" "$hm/config/conf.json" "$hm/other.json"
  run mig 'migrationCopyHostManager "$OLD"'
  [ "$status" -eq 0 ]
  for f in applications.json applications.json.bk net_itf_blacklist.json net_itf_blacklist.json.bk \
    net_rng_blacklist.json net_rng_blacklist.json.bk; do
    cmp "$hm/$f" "$OLD/state/host-manager/$f"
    [ -e "$hm/$f" ]
  done
  [ "$(stat -c %a "$OLD/state/host-manager/applications.json")" = "600" ]
  # only the data files: not the binary, its config or anything else
  [ "$(ls "$OLD/state/host-manager" | wc -l)" -eq 6 ]
}

@test "without data files, or without the host-manager's folder, state/host-manager is created empty" {
  mkdir -p "$OLD/bin/SENERGY-Platform/mgw-host-manager/config"
  touch "$OLD/bin/SENERGY-Platform/mgw-host-manager/bin"
  run mig 'migrationCopyHostManager "$OLD"'
  [ "$status" -eq 0 ]
  [ -d "$OLD/state/host-manager" ] && [ -z "$(ls -A "$OLD/state/host-manager")" ]
  rm -rf "$OLD/bin" "$OLD/state"
  run mig 'migrationCopyHostManager "$OLD"'
  [ "$status" -eq 0 ]
  [ -d "$OLD/state/host-manager" ] && [ -z "$(ls -A "$OLD/state/host-manager")" ]
}
