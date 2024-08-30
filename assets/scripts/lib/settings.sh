#!/bin/sh

systemd_path=/etc/systemd/system
logrotated_path=/etc/logrotate.d
avahi_path=/etc/avahi/services
cron_path=/etc/cron.daily
base_path=/opt/mgw
secrets_path=""
deployments_path=""
sockets_path=""
bin_path=""
container_path=""
log_path=""
scripts_path=""
mounts_path=""
stack_name=""
core_db_pw=""
core_db_root_pw=""
subnet_core="10.0.0.0"
subnet_module="10.1.0.0"
subnet_gateway="10.10.0.0"
systemd=""
logrotate=""
cron=""
advertise=""
platform=""
arch=""
core_id=""
core_name=""
gateway_port="8080"
allow_beta=""
core_usr_pw=""

saveSettings() {
  echo \
"base_path=$base_path
secrets_path=$secrets_path
deployments_path=$deployments_path
sockets_path=$sockets_path
bin_path=$bin_path
container_path=$container_path
log_path=$log_path
scripts_path=$scripts_path
mounts_path=$mounts_path
stack_name=$stack_name
subnet_core=$subnet_core
subnet_module=$subnet_module
subnet_gateway=$subnet_gateway
core_db_pw=$core_db_pw
core_db_root_pw=$core_db_root_pw
systemd_path=$systemd_path
logrotated_path=$logrotated_path
avahi_path=$avahi_path
cron_path=$cron_path
systemd=$systemd
logrotate=$logrotate
cron=$cron
advertise=$advertise
platform=$platform
arch=$arch
core_id=$core_id
core_name=$core_name
gateway_port=$gateway_port
allow_beta=$allow_beta
core_usr_pw=$core_usr_pw" \
  > $base_path/.settings
}

exportSettingsToEnv() {
  export \
    BASE_PATH="$base_path" \
    SECRETS_PATH="$secrets_path" \
    DEPLOYMENTS_PATH="$deployments_path" \
    SOCKETS_PATH="$sockets_path" \
    MOUNTS_PATH="$mounts_path" \
    BIN_PATH="$bin_path" \
    AVAHI_PATH="$avahi_path" \
    CONTAINER_PATH="$container_path" \
    LOG_PATH="$log_path" \
    SUBNET_CORE="$subnet_core" \
    SUBNET_MODULE="$subnet_module" \
    SUBNET_GATEWAY="$subnet_gateway" \
    CORE_DB_PW="$core_db_pw" \
    CORE_DB_ROOT_PW="$core_db_root_pw" \
    COMPOSE_PROJECT_NAME="$stack_name" \
    CORE_ID="$core_id" \
    CORE_NAME="$core_name" \
    GATEWAY_PORT="$gateway_port" \
    CORE_USR_PW="$core_usr_pw"
}