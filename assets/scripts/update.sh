#!/bin/sh

script_path=${0%/*}
if ! cd $script_path
then
  exit 1
fi

repo="SENERGY-Platform/mgw-core-installer"

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
    echo "new release: $new_version"
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
    echo "starting update ..."
    $extract_path/assets/update.sh "$base_path" &
  else
    echo "latest release at $new_version, nothing to do"
  fi
}

if [ "$1" = "" ]
then
  . ./scripts/util.sh
  . ./scripts/github.sh
  . ./.settings
  version="$(cat .version)"
  echo "installed release: $version"
  handleRelease
  exit
fi

. ./lib/settings.sh
. ./lib/util.sh
. ./lib/os.sh
. ./lib/github.sh
. ./lib/docker.sh
. $1/.settings
