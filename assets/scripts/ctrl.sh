#!/bin/sh

script_path=${0%/*}
if ! cd $script_path
then
  exit 1
fi

. ./scripts/docker.sh
. ./.settings

start() {
  pid=""
  echo "mounting secrets tmpfs ..."
  if ! mount -t tmpfs -o size=100M tmpfs $secrets_path
  then
    exit 1
  fi
  echo "starting ce-wrapper ..."
  $bin_path/SENERGY-Platform/mgw-container-engine-wrapper/bin -config=$bin_path/SENERGY-Platform/mgw-container-engine-wrapper/config/conf.json &
  pid="${pid}$!"
  echo "starting host-manager ..."
  $bin_path/SENERGY-Platform/mgw-host-manager/bin -config=$bin_path/SENERGY-Platform/mgw-host-manager/config/conf.json &
  pid="${pid} $!"
  echo "$pid" > $base_path/.pid
}

stop() {
  echo "stopping processes ..."
  for pid in ${1}
  do
    if ! kill $pid
    then
      exit 1
    fi
  done
  echo "unmounting secrets tmpfs ..."
  if ! umount $secrets_path
  then
    exit 1
  fi
}

if ! [ "$(id -u)" = "0" ]
then
  echo "root privileges required"
  exit 1
fi
case $1 in
start)
  start
  ;;
stop)
  if ! pid="$(cat $base_path/.pid)"
  then
    exit 1
  fi
  if [ "$pid" != "" ]
  then
    stop "$pid"
    rm $base_path/.pid
  fi
  ;;
*)
  echo "unknown option"
  exit 1
esac