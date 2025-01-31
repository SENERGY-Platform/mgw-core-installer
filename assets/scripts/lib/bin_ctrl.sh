#!/bin/sh

mountTmpfs() {
  res=$(stat -f -c '%T' $secrets_path)
  if [ "$res" != "tmpfs" ]
  then
    echo "mounting tmpfs ..."
    if ! mount -t tmpfs -o size=100M tmpfs $secrets_path
    then
      exit 1
    fi
  fi
}

unmountTmpfs() {
  echo "unmounting tmpfs ..."
  umount -f $secrets_path
}

startBin() {
  if [ -e $base_path/.pid ]
  then
    return
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
      kill $pid
    done
    rm $base_path/.pid
  fi
}
