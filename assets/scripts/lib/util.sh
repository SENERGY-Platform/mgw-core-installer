#!/bin/sh

yellow="\e[93;1m"
blue="\e[96;1m"

downloadFile() {
  path="$2/$(basename "$1")"
  if ! curl -L -s -o "$path" "$1"
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