#!/bin/sh

. ./lib.sh

installed() {
    command -v "$1" > /dev/null
    return $?
}

getMissing() {
  missing=""
  for dep in ${1}
  do
    if ! installed "$dep"
    then
      if [ "$missing" = "" ]; then
        missing="${missing}$dep"
      else
        missing="${missing} $dep"
      fi
    fi
  done
  echo "$missing"
}

handlePackages() {
  missing=$(getMissing "systemd systemctl apt-get docker")
  if ! [ "$missing" = "" ]
  then
    printf "missing required packages: %s\n" "$missing"
    exit 1
  fi
  missing=$(getMissing "curl tar gzip jq avahi-daemon")
  if ! [ "$missing" = "" ]
  then
    checkRoot
    printf "the following new packages will be installed: %s \n" "$missing"
    while :
    do
      printf "continue? [y/n] "
      read -r choice
      case "$choice" in
      "y")
        if ! apt-get update
        then
          exit 1
        fi
        if ! apt-get install -y "$missing"
        then
          exit 1
        fi
        break
        ;;
      "n")
        exit 0
        ;;
      *)
        echo "unknown option"
      esac
    done
  fi
}

