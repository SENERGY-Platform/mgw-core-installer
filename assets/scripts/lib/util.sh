#!/bin/sh

yellow="\e[93;1m"
blue="\e[96;1m"

# a download has no overall limit, a slow link may well need long for a large
# file. it fails once it cannot connect within 30s or stalls below 1 KiB/s for
# 60s, which is what a connection that will never finish looks like
downloadFile() {
  path="$2/$(basename "$1")"
  if ! curl -L -s --connect-timeout 30 --speed-limit 1024 --speed-time 60 -o "$path" "$1"
  then
    return 1
  fi
  echo "$path"
}

extractTar() {
  file=$(basename "$1")
  path="${1%%/$file}/extract"
  mkdir -p "$path"
  if ! tar -xf "$1" -C "$path"
  then
    return 1
  fi
  echo "$path"
}

getTemplateBase() {
  if [ "${1##*.}" = "template" ]; then
    echo "${1%%.template}"
    return 0
  fi
  return 1
}

readFileToArray() {
  items=""
  while read -r line || [ -n "$line" ]
  do
    if [ "$items" = "" ]
    then
      items="${items}$line"
    else
      items="${items} $line"
    fi
  done < "$1"
  echo "$items"
}

inArray() {
  for item in ${1}
  do
    if [ "$item" = "$2" ]
    then
      return 0
    fi
  done
  return 1
}

inMap() {
  for item in ${1}
  do
    key="${item%%:*}"
    if [ "$key" = "$2" ]
    then
      echo "${item##*:}"
      return 0
    fi
  done
  return 1
}

copyWithTemplates() {
  items="$3"
  if ! files=$(ls $1)
  then
    return 1
  fi
  if [ "$files" != "" ]
  then
    for file in ${files}
    do
      if real_file="$(getTemplateBase "$file")"
      then
        if ! envsubst < $1/$file > $2/$4$real_file
        then
          return 1
        fi
        file="$4$real_file"
      else
        if ! cp $1/$file $2/$4$file
        then
          return 1
        fi
        file="$4$file"
      fi
      if [ "$items" = "" ]; then
        items="${items}$file"
      else
        items="${items} $file"
      fi
    done
  fi
  echo "$items"
}

isRoot() {
  if [ "$(id -u)" = "0" ]
  then
     return 0
  fi
  return 1
}

printColor() {
  format="%s"
  if [ "$auto" = "false" ] || [ "$auto" = "" ]
  then
    format="$2%s\e[0m"
  fi
  if [ "$3" != "nb" ]
  then
    format="$format\n"
  fi
  printf $format "$1"
}

printLnBr() {
  if [ "$auto" = "false" ] || [ "$auto" = "" ]
  then
    echo
  fi
}

# keeps a second update from running while one is still active - a hung
# automatic update would otherwise be joined by the next cron run, which removes
# the extracted release the first one installs from. the lock is host-wide like
# the working space both share. it is held on fd 9 and released by the kernel
# when the process holding it exits, so a crash or reboot leaves no stale lock.
# stage one exports MGW_UPDATE_LOCKED for the stage two it starts, which
# inherits fd 9 and only confirms it holds the lock - opening the lock file
# anew would block against its own parent. a stage two run directly takes the
# lock itself. anything started for good while it is held must close fd 9, see
# startProc. returns 2 if another update holds the lock, 1 on any other failure
acquireUpdateLock() {
  if [ "$MGW_UPDATE_LOCKED" = "true" ] && flock -n 9 2> /dev/null
  then
    return 0
  fi
  if ! command -v flock > /dev/null
  then
    echo "flock not found"
    return 1
  fi
  if ! mkdir -p "${update_lock%/*}"
  then
    return 1
  fi
  exec 9> "$update_lock"
  if ! flock -n 9
  then
    echo "another update is running, aborting"
    return 2
  fi
  export MGW_UPDATE_LOCKED=true
}
