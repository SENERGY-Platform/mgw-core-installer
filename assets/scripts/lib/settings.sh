#!/bin/sh

systemd_path=/etc/systemd/system
logrotated_path=/etc/logrotate.d
avahi_path=/etc/avahi/services
cron_path=/etc/cron.daily
docker_socket_path=/var/run/docker.sock
base_path=/opt/mgw
host_dir_repository_path="$base_path/repositories/host_dir"
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
subnet_core_default="10.0.0.0"
subnet_core="$subnet_core_default"
subnet_module_default="10.1.0.0"
subnet_module="$subnet_module_default"
subnet_gateway_default="10.10.0.0"
subnet_gateway="$subnet_gateway_default"
systemd=""
ctr_restart_policy=""
logrotate=""
cron=""
advertise=""
platform=""
arch=""
core_id=""
core_name=""
gateway_port_default="8080"
gateway_port="$gateway_port_default"
allow_beta=""
core_usr_default="core-user"
core_usr="$core_usr_default"
core_usr_pw=""

# the core user can be emptied from a config file or a setup prompt. an empty
# II_USER leaves the auth service without an identity to log into the identity
# server with, which no template rendering complains about, so an empty value
# falls back to the default instead of reaching the compose file
handleCoreUser() {
  if [ "$core_usr" = "" ]
  then
    core_usr="$core_usr_default"
  fi
}

# an empty gateway port leaves the compose port mapping without a port and the
# public api config with a bare 'listen ;', so the gateway never comes up
handleGatewayPort() {
  if [ "$gateway_port" = "" ]
  then
    gateway_port="$gateway_port_default"
  fi
}

# an empty subnet reaches the ipam config of a compose network, the nginx
# allow/deny rules of the internal api and the net ranges of the host manager,
# none of which mean anything without an address
handleSubnets() {
  if [ "$subnet_core" = "" ]
  then
    subnet_core="$subnet_core_default"
  fi
  if [ "$subnet_module" = "" ]
  then
    subnet_module="$subnet_module_default"
  fi
  if [ "$subnet_gateway" = "" ]
  then
    subnet_gateway="$subnet_gateway_default"
  fi
}

# derives the restart policy of the core containers from the startup
# integration. without systemd nothing stops the containers on shutdown, so a
# policy that survives a reboot brings them back while the host binaries stay
# down - the state a user lands in whenever they forget 'ctrl.sh stop'
handleRestartPolicy() {
  if [ "$ctr_restart_policy" = "" ]
  then
    if [ "$systemd" = "true" ]
    then
      ctr_restart_policy="unless-stopped"
    else
      ctr_restart_policy="no"
    fi
  fi
}

saveSettings() {
  echo \
"base_path=$base_path
secrets_path=$secrets_path
deployments_path=$deployments_path
sockets_path=$sockets_path
host_dir_repository_path=$host_dir_repository_path
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
docker_socket_path=$docker_socket_path
systemd=$systemd
ctr_restart_policy=$ctr_restart_policy
logrotate=$logrotate
cron=$cron
advertise=$advertise
platform=$platform
arch=$arch
core_id=$core_id
core_name=$core_name
gateway_port=$gateway_port
allow_beta=$allow_beta
core_usr=$core_usr
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
    DOCKER_SOCKET_PATH="$docker_socket_path" \
    LOG_PATH="$log_path" \
    HOST_DIR_REPOSITORY_PATH="$host_dir_repository_path" \
    SUBNET_CORE="$subnet_core" \
    SUBNET_MODULE="$subnet_module" \
    SUBNET_GATEWAY="$subnet_gateway" \
    CORE_DB_PW="$core_db_pw" \
    CORE_DB_ROOT_PW="$core_db_root_pw" \
    COMPOSE_PROJECT_NAME="$stack_name" \
    CORE_ID="$core_id" \
    CORE_NAME="$core_name" \
    GATEWAY_PORT="$gateway_port" \
    CORE_USR="$core_usr" \
    CORE_USR_PW="$core_usr_pw" \
    CTR_RESTART_POLICY="$ctr_restart_policy"
}