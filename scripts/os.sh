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
      return 1
  fi
  case "$plf" in
    Linux)
      echo $plf_linux
      ;;
#    Darwin)
#      echo $plf_darwin
#      ;;
    *)
      return 1
  esac
}

getArch() {
  if ! plf="$(uname -m)"
  then
    return 1
  fi
  case "$plf" in
    x86_64)
      echo $arch_amd64
      ;;
#    i386)
#      echo $arch_386
#      ;;
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
      return 1
  esac
}

checkRoot() {
  if ! [ "$(id -u)" = "0" ]
  then
     return 1
  fi
}