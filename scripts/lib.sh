#!/bin/sh

plf_linux="linux"
plf_darwin="darwin"

arch_386="386"
arch_amd64="amd64"
arch_arm="arm"
arch_arm64="arm64"

getPlatform() {
  if ! plf="$(uname -s)"
  then
      exit 1
  fi
  case "$plf" in
    Linux)
      echo $plf_linux
      ;;
#    Darwin)
#      echo $plf_darwin
#      ;;
    *)
      echo "platform not supported"
      exit 1
  esac
}

getArch() {
  if ! plf="$(uname -m)"
  then
    exit 1
  fi
  case "$plf" in
    x86_64)
      echo $arch_amd64
      ;;
    i386)
      echo $arch_386
      ;;
    aarch64)
      echo $arch_arm64
      ;;
    armv8l)
      echo $arch_arm64
      ;;
    armv7l)
      echo $arch_arm
      ;;
    *)
      echo "architecture not supported"
      exit 1
  esac
}

checkRoot() {
  if ! [ "$(id -u)" = "0" ]
  then
     echo "root privileges required"
     exit 1
  fi
}

download() {
  path="$2/$(basename "$1")"
  if ! curl -L -o "$path" "$1"
  then
    exit 1
  fi
  echo "$path"
}