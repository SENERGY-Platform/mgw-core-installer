#!/bin/sh

. ./assets/scripts/lib.sh
. ./assets/scripts/os.sh
. ./assets/scripts/package.sh
. ./assets/scripts/github.sh

require_pkg="systemd apt docker"
install_pkg="curl tar gzip jq avahi-daemon"
binaries="SENERGY-Platform/mgw-container-engine-wrapper SENERGY-Platform/mgw-host-manager"
base_path="/opt/mgw/"

if ! platform="$(getPlatform)"
then
  echo "platform not supported"
  exit 1
fi
if ! arch="$(getArch)"
then
  echo "architecture not supported"
  exit 1
fi

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
    printf "the following new packages will be installed: %s \n" "$missing"
    while :
    do
      printf "continue? [y/n] "
      read -r choice
      case "$choice" in
      "y")
        if ! installPkg "$missing"
        then
          exit 1
        fi
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

prepareInstallDir() {
  mkdir -p $base_path/deployments $base_path/secrets $base_path/sockets $base_path/bin
}

handleBin() {
  wrk_spc="/tmp/mgw-install"
  mkdir -p $wrk_spc
  for repo in ${binaries}
  do
    echo "checking latest $repo release ..."
    if ! release="$(getGitHubRelease "$repo")"
    then
      exit 1
    fi
    if ! version="$(getGitHubReleaseVersion "$release")"
    then
      exit 1
    fi
    echo "downloading $version ..."
    if ! asset_url="$(getGitHubReleaseAssetUrl "$release" "$platform")"
    then
      exit 1
    fi
    dl_pth="$wrk_spc/$repo"
    mkdir -p $dl_pth
    if ! file="$(downloadFile "$asset_url" "$dl_pth")"
    then
      exit 1
    fi
    echo "installing ..."
    if ! extract_path="$(extractTar "$file")"
    then
      exit 1
    fi
    target_path="$base_path/bin/$repo"
    mkdir -p $target_path
    if ! cp -r $extract_path/$arch/* $target_path
    then
      exit 1
    fi
    echo "$repo $version" >> $base_path/bin/versions
  done
  rm -r "$wrk_spc"
}

if ! checkRoot
then
  echo "root privileges required"
  exit 1
fi
handlePackages
prepareInstallDir
handleBin