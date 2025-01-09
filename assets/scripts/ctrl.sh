#!/bin/sh

script_path=${0%/*}
if ! cd $script_path
then
  exit 1
fi

. ./scripts/docker.sh
. ./scripts/settings.sh
. ./.settings

export COMPOSE_PROJECT_NAME="$stack_name"

mountTmpfs() {
  echo "mounting tmpfs ..."
  if ! mount -t tmpfs -o size=100M tmpfs $secrets_path
  then
    exit 1
  fi
}

unmountTmpfs() {
  echo "unmounting tmpfs ..."
  if ! umount $secrets_path
  then
    exit 1
  fi
}

startBin() {
  if [ -e $base_path/.pid ]
  then
    exit 1
  fi
  echo "starting processes ..."
  pid=""
  $bin_path/SENERGY-Platform/mgw-container-engine-wrapper/bin -config=$bin_path/SENERGY-Platform/mgw-container-engine-wrapper/config/conf.json &
  pid="${pid}$!"
  $bin_path/SENERGY-Platform/mgw-host-manager/bin -config=$bin_path/SENERGY-Platform/mgw-host-manager/config/conf.json &
  pid="${pid} $!"
  $bin_path/SENERGY-Platform/mgw-core-manager/bin -config=$bin_path/SENERGY-Platform/mgw-core-manager/config/conf.json &
  pid="${pid} $!"
  echo "$pid" > $base_path/.pid
}

stopBin() {
  if ! pid="$(cat $base_path/.pid)"
  then
    exit 1
  fi
  if [ "$pid" != "" ]
  then
    echo "stopping processes ..."
    for pid in ${pid}
    do
      if ! kill $pid
      then
        exit 1
      fi
    done
    rm $base_path/.pid
  fi
}

startContainers() {
  echo "starting containers ..."
  if ! cd $container_path
  then
    exit 1
  fi
  if ! dockerCompose start
  then
    exit 1
  fi
  if ! cd $script_path
  then
    exit 1
  fi
}

stopContainers() {
  echo "stopping containers ..."
  if ! cd $container_path
  then
    exit 1
  fi
  if ! dockerCompose stop
  then
    exit 1
  fi
  if ! cd $script_path
  then
    exit 1
  fi
}

createContainers() {
  echo "creating containers ..."
  if ! cd $container_path
  then
    exit 1
  fi
  if ! dockerCompose up --no-start
  then
    exit 1
  fi
  if ! cd $script_path
  then
    exit 1
  fi
}

removeContainers() {
  echo "removing containers ..."
  if ! cd $container_path
  then
    exit 1
  fi
  if ! dockerCompose rm -s -f
  then
    exit 1
  fi
  if ! cd $script_path
  then
    exit 1
  fi
}

purgeContainers() {
  echo "purging containers ..."
  if ! cd $container_path
  then
    exit 1
  fi
  if ! dockerCompose down -v
  then
    exit 1
  fi
  if ! cd $script_path
  then
    exit 1
  fi
}

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
    if [ "$systemd" = "true" ]
    then
      echo "systemd integration enabled, operation not allowed"
      exit 1
    fi
}

if ! [ "$(id -u)" = "0" ]
then
  echo "root privileges required"
  exit 1
fi
detectDockerCompose
case $1 in
start)
  checkSystemd
  startBin
  mountTmpfs
  startContainers
  ;;
stop)
  checkSystemd
  stopContainers
  unmountTmpfs
  stopBin
  ;;
prc-start)
  checkSystemd
  startBin
  ;;
prc-stop)
  checkSystemd
  stopBin
  ;;
ctr-start)
  checkSystemd
  mountTmpfs
  startContainers
  ;;
ctr-stop)
  checkSystemd
  stopContainers
  unmountTmpfs
  ;;
ctr-create)
  checkSystemd
  createContainers
  ;;
ctr-remove)
  checkSystemd
  removeContainers
  ;;
ctr-recreate)
  checkSystemd
  removeContainers
  createContainers
  ;;
ctr-purge)
  checkSystemd
  purgeContainers
  ;;
beta-test)
  handleBetaRelease
  ;;
*)
  echo "unknown option"
  exit 1
esac