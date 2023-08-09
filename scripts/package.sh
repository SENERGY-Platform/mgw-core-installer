#!/bin/sh

isAvailable() {
    command -v "$1" > /dev/null
    return $?
}

getMissingCmd() {
  missing=""
  for cmd in ${1}
  do
    if ! isAvailable "$cmd"
    then
      if [ "$missing" = "" ]; then
        missing="${missing}$cmd"
      else
        missing="${missing} $cmd"
      fi
    fi
  done
  echo "$missing"
}

installPkg() {
  if ! apt-get update
  then
    return 1
  fi
  if ! apt-get install -y "$1"
  then
    return 1
  fi
}
