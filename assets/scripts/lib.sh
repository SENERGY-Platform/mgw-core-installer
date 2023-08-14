#!/bin/sh

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