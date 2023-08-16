#!/bin/sh

script_path=${0%/*}
if ! cd $script_path
then
  exit 1
fi

repo="SENERGY-Platform/mgw-core-installer"
install_path=""

handleRelease() {
  echo "checking for new release ..."
  if ! release="$(getGitHubRelease "$repo")"
  then
    exit 1
  fi
  if ! new_version="$(getGitHubReleaseVersion "$release")"
  then
    exit 1
  fi
  if [ "$new_version" != "null" ] && [ "$version" != "$new_version" ]
  then
    echo "new release available: $new_version"
    while :
    do
      printf "\e[96;1update? (y/n):\e[0m "
      read -r choice
      case $choice in
      y|"")
        break
        ;;
      n)
        exit 0
        ;;
      *)
        echo "unknown option"
      esac
    done
    wrk_spc="/tmp/mgw-update"
    if ! mkdir -p $wrk_spc
    then
      exit 1
    fi
    if ! asset_url="$(getGitHubReleaseAssetUrl "$release" "$new_version")"
    then
      rm -r "$wrk_spc"
      exit 1
    fi
    echo "downloading ..."
    if ! file="$(downloadFile "$asset_url" "$wrk_spc")"
    then
      rm -r "$wrk_spc"
      exit 1
    fi
    echo "extracting ..."
    if ! extract_path="$(extractTar "$file")"
    then
      rm -r "$wrk_spc"
      exit 1
    fi
    $extract_path/assets/update.sh "$base_path"
  else
    echo "latest release at $new_version, nothing to do"
  fi
}

handlePackages() {
  missing=$(getMissingPkg "$install_pkg")
  if [ "$missing" != "" ]
  then
    printf "\e[96;1mthe following new packages will be installed:\e[0m %s \n" "$missing"
    while :
    do
      printf "\e[96;1mcontinue? (y/n):\e[0m "
      read -r choice
      case "$choice" in
      y|"")
        if ! installPkg "$missing"
        then
          exit 1
        fi
        break
        ;;
      n)
        exit 0
        ;;
      *)
        echo "unknown option"
      esac
    done
  fi
}

checkRoot() {
  if ! isRoot
  then
    echo "root privileges required"
    exit 1
  fi
}

if [ "$1" = "" ]
then
  . ./scripts/util.sh
  . ./scripts/github.sh
  . ./.settings
  checkRoot
  version="$(cat .version)"
  echo "installed release: $version"
  handleRelease
  exit
fi

cd ../..

install_path=$1

. ./assets/scripts/lib/var
. ./assets/scripts/lib/settings.sh
. ./assets/scripts/lib/util.sh
. ./assets/scripts/lib/os.sh
. ./assets/scripts/lib/package.sh
. ./assets/scripts/lib/github.sh
. ./assets/scripts/lib/docker.sh
. $1/.settings
. $install_path/.settings

