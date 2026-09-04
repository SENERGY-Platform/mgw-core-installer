#!/bin/sh

script_path=${0%/*}
if ! cd $script_path
then
  exit 1
fi

. ./scripts/util.sh
. ./scripts/bin_ctrl.sh
. ./scripts/sysd_ctrl.sh
. ./scripts/ctr_ctrl.sh
. ./scripts/container.sh
. ./scripts/settings.sh
. ./.options
. ./.settings

export COMPOSE_PROJECT_NAME="$stack_name"

handleBetaRelease() {
  printf "allow beta releases? (y/n): "
  read -r choice
  case "$choice" in
  y)
    allow_beta=true
    ;;
  n)
    allow_beta=false
    ;;
  *)
    echo "unknown option"
    exit 1
  esac
  saveSettings
}

# the containers of a core with systemd integration are not started at boot by
# the units - those only cover the host binaries - but by their docker restart
# policy. disabling the units therefore has to take the policy with it, or the
# containers come back after a reboot without the host binaries
applyRestartPolicy() {
  if [ "$ctr_restart_policy" = "$1" ]
  then
    return
  fi
  echo "setting container restart policy to '$1' ..."
  ctr_restart_policy="$1"
  saveSettings
  exportSettingsToEnv
  parseImages
  renderCompose
  # the policy reaches an existing container only through a recreate, and a
  # recreate leaves it stopped - enable/disable are about the next boot, not
  # about stopping a running core
  running="$(docker ps -q --filter "label=mgw_cid=$core_id")"
  createContainers
  if [ "$running" != "" ]
  then
    startContainers
  fi
}

checkSystemd() {
    if [ "$systemd" != "true" ]
    then
      echo "operation only available with systemd integration"
      exit 1
    fi
}

# TODO remove build-ui
printHelp() {
  printf '%s\n' \
  '' \
  'available options:' \
  '' \
  'start          start the mgw core' \
  'stop           stop the mgw core' \
  'enable         enable systemd units and container autostart' \
  'disable        disable systemd units and container autostart' \
  'ctr-recreate   recreate containers' \
  'ctr-purge      recreate containers and volumes' \
  'beta-test      toggle beta releases' \
  'build-ui       build web-ui' \
  'help           display this help page' \
  ''
}

# TODO remove build-ui
if ! [ "$(id -u)" = "0" ]
then
  echo "root privileges required"
  exit 1
fi
detectDockerCompose
case $1 in
start)
  if [ "$systemd" = "true" ]
  then
    startUnits
  else
    startBin
    mountTmpfs
  fi
  sleep 1
  startContainers
  ;;
stop)
  stopContainers
  if [ "$systemd" = "true" ]
  then
    stopUnits
  else
    unmountTmpfs
    stopBin
  fi
  ;;
enable)
  checkSystemd
  enableUnits
  applyRestartPolicy "unless-stopped"
  ;;
disable)
  checkSystemd
  disableUnits
  applyRestartPolicy "no"
  ;;
ctr-recreate)
  removeContainers
  createContainers
  ;;
ctr-purge)
  purgeContainers
  createContainers
  ;;
beta-test)
  handleBetaRelease
  ;;
build-ui)
  buildWebUI
  ;;
help)
  printHelp
  ;;
*)
  printHelp
  exit 1
  ;;
esac
