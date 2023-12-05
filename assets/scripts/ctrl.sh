#!/bin/sh

script_path=${0%/*}
if ! cd $script_path
then
  exit 1
fi

. ./scripts/docker.sh
. ./scripts/gw_user_file.sh
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

changeGatewayPW() {
  printf "set gateway password: "
  read -r input
  basic_auth_pw="$input"
  handleGatewayUserFile
}

if ! [ "$(id -u)" = "0" ]
then
  echo "root privileges required"
  exit 1
fi
detectDockerCompose
case $1 in
start)
  startBin
  mountTmpfs
  startContainers
  ;;
stop)
  stopContainers
  unmountTmpfs
  stopBin
  ;;
prc-start)
  startBin
  ;;
prc-stop)
  stopBin
  ;;
ctr-start)
  mountTmpfs
  startContainers
  ;;
ctr-stop)
  stopContainers
  unmountTmpfs
  ;;
ctr-create)
  createContainers
  ;;
ctr-remove)
  removeContainers
  ;;
ctr-recreate)
  removeContainers
  createContainers
  ;;
ctr-purge)
  purgeContainers
  ;;
set-pw)
  changeGatewayPW
  ;;
*)
  echo "unknown option"
  exit 1
esac