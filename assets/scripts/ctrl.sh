#!/bin/sh

script_path=${0%/*}
if ! cd $script_path
then
  exit 1
fi

. ./scripts/docker.sh
. ./scripts/util.sh
. ./scripts/bin_ctrl.sh
. ./scripts/sysd_ctrl.sh
. ./scripts/ctr_ctrl.sh
. ./scripts/settings.sh
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

checkSystemd() {
    if [ "$systemd" != "true" ]
    then
      echo "operation only available with systemd integration"
      exit 1
    fi
}

printHelp() {
  printf '%s\n' \
  '' \
  'available options:' \
  '' \
  'start          start the mgw core' \
  'stop           stop the mgw core' \
  'enable         enable systemd units' \
  'disable        disable systemd units' \
  'ctr-recreate   recreate containers' \
  'ctr-purge      recreate containers and volumes' \
  'beta-test      toggle beta releases' \
  'help           display this help page' \
  ''
}

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
  ;;
disable)
  checkSystemd
  disableUnits
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
help)
  printHelp
  ;;
*)
  printHelp
  exit 1
  ;;
esac
