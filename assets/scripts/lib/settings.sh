#!/bin/sh

systemd_path=/etc/systemd/system
logrotated_path=/etc/logrotate.d
mnt_path=/mnt/mgw
base_path=/opt/mgw
secrets_path=""
deployments_path=""
sockets_path=""
bin_path=""
container_path=""
log_path=""
scripts_path=""
stack_name="mgw-core"
core_db_pw=""
core_db_root_pw=""
subnet_core="10.0.0.0"
subnet_module="10.1.0.0"
subnet_gateway="10.10.0.0"
systemd=true
logrotate=true
platform=""
arch=""

saveSettings() {
  echo \
"mnt_path=$mnt_path
base_path=$base_path
secrets_path=$secrets_path
deployments_path=$deployments_path
sockets_path=$sockets_path
bin_path=$bin_path
container_path=$container_path
log_path=$log_path
scripts_path=$scripts_path
stack_name=$stack_name
subnet_core=$subnet_core
subnet_module=$subnet_module
subnet_gateway=$subnet_gateway
core_db_pw=$core_db_pw
core_db_root_pw=$core_db_root_pw
systemd_path=$systemd_path
logrotated_path=$logrotated_path
systemd=$systemd
logrotate=$logrotate
platform=$platform
arch=$arch" \
  > $base_path/.settings
}

exportSettingsToEnv() {
  export \
    BASE_PATH="$base_path" \
    SECRETS_PATH="$secrets_path" \
    DEPLOYMENTS_PATH="$deployments_path" \
    SOCKETS_PATH="$sockets_path" \
    BIN_PATH="$bin_path" \
    CONTAINER_PATH="$container_path" \
    LOG_PATH="$log_path" \
    STACK_NAME="$stack_name" \
    SUBNET_CORE="$subnet_core" \
    SUBNET_MODULE="$subnet_module" \
    SUBNET_GATEWAY="$subnet_gateway" \
    CORE_DB_PW="$core_db_pw" \
    CORE_DB_ROOT_PW="$core_db_root_pw"
}