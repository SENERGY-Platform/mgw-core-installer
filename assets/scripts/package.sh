#!/bin/sh

getMissingPkg() {
  missing=""
  for item in ${1}
  do
    pkg="${item%%:*}"
    cmd="${item##*:}"
    if [ "$cmd" = "" ]
    then
      cmd="$pkg"
    fi
    if ! command -v "$cmd" > /dev/null 2>& 1
    then
      if [ "$missing" = "" ]; then
        missing="${missing}$pkg"
      else
        missing="${missing} $pkg"
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
