#!/bin/sh

script_path=${0%/*}
if ! cd $script_path
then
  exit 1
fi

. ./scripts/docker.sh
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
  echo "starting processes ..."
  pid=""
  $bin_path/SENERGY-Platform/mgw-container-engine-wrapper/bin -config=$bin_path/SENERGY-Platform/mgw-container-engine-wrapper/config/conf.json &
  pid="${pid}$!"
  $bin_path/SENERGY-Platform/mgw-host-manager/bin -config=$bin_path/SENERGY-Platform/mgw-host-manager/config/conf.json &
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

if ! [ "$(id -u)" = "0" ]
then
  echo "root privileges required"
  exit 1
fi
detectDockerCompose
case $1 in
start)
  mountTmpfs
  startBin
  startContainers
  ;;
stop)
  stopContainers
  stopBin
  unmountTmpfs
  ;;
*)
  echo "unknown option"
  exit 1
esac