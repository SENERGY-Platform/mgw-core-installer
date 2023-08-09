#!/bin/sh

downloadFile() {
  path="$2/$(basename "$1")"
  if ! curl -L -s -o "$path" "$1"
  then
    exit 1
  fi
  echo "$path"
}