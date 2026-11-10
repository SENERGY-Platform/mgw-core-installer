#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# The shared building blocks "prepare version" and "activate version" (PLAN.md 10a; install steps 10
# and 11, update phases B and C, restore).
#
# prepare: build the version folder vX_Y_Z from a release's assets plus the effective settings, up
# to the created containers. Everything it creates is recorded first if objects_record is set (the
# install), images always in state/images.
# activate: point current at a version folder, reconcile /etc, reload.
#
# Needs lib/file.sh, lib/settings.sh, lib/state.sh, lib/host.sh, lib/render.sh, lib/reconcile.sh,
# lib/net.sh, lib/docker.sh, lib/objects.sh and lib/core.sh.

# the script links in a version folder (PLAN.md 3)
version_links="ctrl.sh update.sh restore.sh uninstall.sh"

# set by versionActivate when the avahi reload failed, for the caller's record
version_warning=""

# prepares the version $3 (e.g. v1.3.0) in the core root $1 from the assets folder $2: versionCreate,
# then versionBuild. $4 limits each image pull, $5 the container creation, in seconds (0: no limit).
# The install's way; an update runs versionCreate in stage one and versionBuild in stage two.
versionPrepare() {
  versionCreate "$1" "$2" "$3" && versionBuild "$1" "$3" "$4" "$5"
}

# removes a leftover version folder $2 (a name in the core root $1) unless current points to it
# (S3: left over from a killed run; a folder current points to is never touched)
versionRemoveLeftover() {
  if ! [ -e "$1/$2" ]
  then
    return 0
  fi
  if [ "$(readlink "$1/current" 2> /dev/null)" = "$2" ]
  then
    echo "'$1/$2' is the active version" >&2
    return 1
  fi
  echo "removing the leftover $1/$2 ..."
  objectsRemove "$1" "folder:$2"
}

# creates vX_Y_Z_tmp for the version $3 in the core root $1 with the assets from $2 and the script
# links; leftovers with the target names are removed first (S3)
versionCreate() {
  if ! version_folder="$(versionFolder "$3")"
  then
    return 1
  fi
  version_tmp="$1/${version_folder}_tmp"
  versionRemoveLeftover "$1" "${version_folder}_tmp" || return 1
  versionRemoveLeftover "$1" "$version_folder" || return 1
  echo "preparing $3 in $version_tmp ..."
  objectsRecord "folder:${version_folder}_tmp" || return 1
  if ! mkdir "$version_tmp" || ! cp -a "$2" "$version_tmp/assets"
  then
    echo "cannot copy the assets to '$version_tmp'" >&2
    return 1
  fi
  # a git clone has no assets/version, the release build writes it
  if ! [ -e "$version_tmp/assets/version" ] && ! echo "$3" > "$version_tmp/assets/version"
  then
    return 1
  fi
  for version_link in ${version_links}
  do
    if ! ln -s "assets/scripts/$version_link" "$version_tmp/$version_link"
    then
      return 1
    fi
  done
}

# builds the version $2 in the core root $1 from its vX_Y_Z_tmp up to the created containers: the
# effective settings, the pinned keys the version adds (only if $5 is "pin": an update, PLAN.md 8),
# render, the host binaries, the rename to vX_Y_Z, the core's missing networks and volumes, the
# images, the containers. $3 limits each image pull, $4 the container creation, in seconds (0: no
# limit). Leaves the new version's effective settings loaded and its options sourced. Returns 0, 1
# on failure, 3 if rate limited; what it created stays for the caller's error handling.
versionBuild() {
  if ! version_folder="$(versionFolder "$2")"
  then
    return 1
  fi
  version_dir="$1/$version_folder"
  version_tmp="${version_dir}_tmp"
  if ! [ -d "$version_tmp/assets" ]
  then
    echo "'$version_tmp' has no assets" >&2
    return 1
  fi
  if [ "$5" = "pin" ] && [ -f "$version_tmp/assets/settings.pinned" ]
  then
    versionPin "$1/state/settings" "$version_tmp/assets/settings.pinned" || return 1
  fi
  if ! settingsLoad "$version_tmp/assets/settings.defaults" "$1/state/settings"
  then
    return 1
  fi
  # options is the version's own static asset (m2-assets-lib.md, finding 9)
  # shellcheck disable=SC1091
  . "$version_tmp/assets/options" || return 1
  if ! renderVersion "$version_tmp" "$1" "$2" "$version_folder"
  then
    return 1
  fi
  versionDownloadBins "$version_tmp"
  version_rc=$?
  if [ $version_rc -ne 0 ]
  then
    return $version_rc
  fi
  versionRemoveLeftover "$1" "$version_folder" || return 1
  objectsRecord "folder:$version_folder" || return 1
  if ! mv -T "$version_tmp" "$version_dir"
  then
    echo "cannot rename '$version_tmp'" >&2
    return 1
  fi
  if ! versionCoreObjects "$version_dir"
  then
    return 1
  fi
  version_images=""
  # shellcheck disable=SC2154 # images comes from options
  for version_image in ${images}
  do
    version_images="$version_images ${version_image#*=}"
  done
  # shellcheck disable=SC2086 # one argument per image
  dockerPullImages "$1/state/images" "$3" $version_images
  version_rc=$?
  if [ $version_rc -ne 0 ]
  then
    return $version_rc
  fi
  echo "creating containers ..."
  objectsRecord "project:$(settingsGet core_name)_$version_folder" || return 1
  if ! dockerCompose "$4" -f "$version_dir/config/container/docker-compose.yml" up --no-start --pull never
  then
    echo "creating the containers of $2 failed" >&2
    return 1
  fi
}

# adds the keys of the pinned file $2 (key=value, the values that keep an existing core's behaviour)
# to the settings file $1, each only if it is missing: an update may add a key, never change one
# (PLAN.md 8, m5-update.md finding 4)
versionPin() {
  while IFS= read -r version_pin_line || [ -n "$version_pin_line" ]
  do
    if settingsParseLine "$version_pin_line"
    then
      # shellcheck disable=SC2154 # set by settingsParseLine
      settingsAdd "$1" "$settings_line_key" "$settings_line_value" || return 1
    fi
  done < "$2"
}

# downloads the host binaries listed in options (binaries: <repo>:<version>) into the version folder
# $1: bin/<repo>/ gets the release archive's folder for this architecture
versionDownloadBins() {
  if ! version_platform="$(hostPlatform)" || ! version_arch="$(hostArch)"
  then
    return 1
  fi
  version_dl="$1/.download"
  # shellcheck disable=SC2154 # binaries comes from options
  for version_item in ${binaries}
  do
    version_repo="${version_item%%:*}"
    version_tag="${version_item#*:}"
    echo "downloading $version_repo $version_tag ..."
    rm -rf "$version_dl"
    if ! mkdir -p "$version_dl/x"
    then
      return 1
    fi
    githubRelease "$version_repo" "$version_tag" "$version_dl/release.json"
    version_rc=$?
    [ $version_rc -eq 0 ] || return $version_rc
    version_url="$(githubAssetUrl "$version_dl/release.json" "$version_platform.tar.gz")" || return 1
    netDownload "$version_url" "$version_dl/bin.tar.gz"
    version_rc=$?
    [ $version_rc -eq 0 ] || return $version_rc
    if ! tar -xzf "$version_dl/bin.tar.gz" -C "$version_dl/x" || ! [ -f "$version_dl/x/$version_arch/bin" ]
    then
      echo "the release of $version_repo $version_tag has no binary for $version_arch" >&2
      return 1
    fi
    if ! mkdir -p "$1/bin/$version_repo" || ! cp -a "$version_dl/x/$version_arch/." "$1/bin/$version_repo/"
    then
      return 1
    fi
  done
  rm -rf "$version_dl"
}

# creates the core's networks and volumes that don't exist (7): networks from objectsNetworks, volumes
# from the rendered compose file of the version folder $1, so there is no second list
versionCoreObjects() {
  version_cid="$(settingsGet core_id)"
  objectsNetworks | while read -r version_net version_subnet
  do
    objectsNetwork "$version_net" "$version_subnet" "$version_cid" || exit 1
  done || return 1
  if ! version_vols="$(docker compose -f "$1/config/container/docker-compose.yml" config --format json | jq -r '.volumes[]?.name')"
  then
    echo "cannot read the volumes of '$1'" >&2
    return 1
  fi
  for version_vol in ${version_vols}
  do
    objectsVolume "$version_vol" "$version_cid" || return 1
  done
}

# points current of the core root $1 at the version folder $2 (atomically: a new link renamed over
# the old one), reconciles /etc and reloads avahi. A failed avahi reload is a warning
# (version_warning), not a failure (PLAN.md 5).
versionActivate() {
  version_warning=""
  if ! [ -d "$1/$2" ]
  then
    echo "'$1/$2' not found" >&2
    return 1
  fi
  echo "activating $2 ..."
  objectsRecord "link:current" || return 1
  if ! ln -sfn "$2" "$1/.current.$$" || ! mv -T "$1/.current.$$" "$1/current"
  then
    rm -f "$1/.current.$$"
    echo "cannot point current at $2" >&2
    return 1
  fi
  objectsRecord "etclinks:" || return 1
  if ! reconcileEtc "$1"
  then
    return 1
  fi
  if [ "$(settingsGet advertise)" = "true" ]
  then
    if ! { systemctl reload avahi-daemon 2> /dev/null || avahi-daemon --reload 2> /dev/null; }
    then
      version_warning="avahi reload failed"
      echo "warning: $version_warning" >&2
    fi
  fi
}
