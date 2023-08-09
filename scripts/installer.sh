#!/bin/sh

. ./os.sh
. ./package.sh
. ./github.sh

require_pkg="systemd apt docker"
install_pkg="curl tar gzip jq avahi-daemon"
binaries="SENERGY-Platform/mgw-container-engine-wrapper SENERGY-Platform/mgw-host-manager"

handlePackages() {
  missing=$(getMissingCmd "$require_pkg")
  if ! [ "$missing" = "" ]
  then
    printf "missing required packages: %s\n" "$missing"
    exit 1
  fi
  missing=$(getMissingCmd "$install_pkg")
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
        installPkg "$missing"
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

platform="$(getPlatform)"
arch="$(getArch)"
handlePackages