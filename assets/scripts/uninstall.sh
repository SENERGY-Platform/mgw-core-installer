#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# Removes everything of a core (PLAN.md 10c), also what a partial install, a broken core or a killed
# update left behind. No options to keep data.
#
#   <core root>/current/uninstall.sh [-y]                  the normal case
#   ./uninstall.sh -path=<core root> [-y]                  from a release archive, if every version
#                                                          folder of the core is broken
#
# It needs state/settings: the core's objects are found by the names stored there (core id, core name,
# stack name) and by the label mgw_cid. Best effort: a step that fails doesn't stop the others; what
# couldn't be removed is listed at the end and the exit code is 1. An image a container outside the
# core still uses is kept and named, without affecting the exit code.

# the libraries' variables are used across files, which shellcheck can't follow
# shellcheck disable=SC2034,SC2154

usage() {
  echo "usage: $0 [-path=<core root>] [-y] [-h]"
  echo "  -path  the core to remove, defaults to the core this script belongs to"
  echo "  -y     remove without asking for confirmation"
}

core_root=""
confirmed=false
for arg in "$@"
do
  case "$arg" in
    -path=*)
      core_root="${arg#-path=}"
      ;;
    -y)
      confirmed=true
      ;;
    -h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
  esac
done

# the script's own folder (assets/scripts), also when started through a link
script_dir="$(dirname "$(readlink -f "$0")")"
lib="$script_dir/lib"
for uninstall_lib in file settings state lock host objects core
do
  # shellcheck disable=SC1090
  . "$lib/$uninstall_lib.sh" || exit 1
done

if [ "$core_root" = "" ]
then
  # started as <core root>/<version folder>/uninstall.sh (a link) or as its target in assets/scripts
  for uninstall_candidate in "$(dirname "$0")/.." "$script_dir/../../.."
  do
    if [ -f "$uninstall_candidate/state/settings" ]
    then
      core_root="$uninstall_candidate"
      break
    fi
  done
fi
if [ "$core_root" = "" ] || ! core_root="$(cd "$core_root" 2> /dev/null && pwd -P)"
then
  echo "no core found; give its core root with -path=<core root>" >&2
  exit 1
fi
if ! [ -f "$core_root/state/settings" ]
then
  echo "'$core_root' has no state/settings: no core of this installer, or its settings are lost" >&2
  exit 1
fi
if [ "$(id -u)" != "0" ]
then
  echo "root privileges required" >&2
  exit 1
fi
if ! settingsLoad "$script_dir/../settings.defaults" "$core_root/state/settings"
then
  exit 1
fi
core_id="$(settingsGet core_id)"
core_name="$(settingsGet core_name)"
stack_name="$(settingsGet stack_name)"
if [ "$core_id" = "" ] || [ "$core_name" = "" ] || [ "$stack_name" = "" ]
then
  echo "state/settings lacks the core id, core name or stack name" >&2
  exit 1
fi

if [ "$confirmed" != "true" ]
then
  echo "this removes the core"
  echo "  core id:   $core_id"
  echo "  core name: $core_name"
  echo "  core root: $core_root"
  echo "with all its data, the data of its modules included. It can't be restored afterwards."
  printf 'remove it? (y/n): '
  read -r answer
  if [ "$answer" != "y" ]
  then
    echo "nothing removed"
    exit 0
  fi
fi

lockAcquire "$core_root/state/lock" uninstall.sh
case $? in
  0)
    ;;
  2)
    echo "an update or ctrl.sh is working on the core, try again later" >&2
    exit 1
    ;;
  *)
    exit 1
esac

left=""
# images kept because containers outside the core use them (step 3)
kept=""
# notes what couldn't be removed
leftover() {
  echo "  could not remove: $*" >&2
  left="${left}  $*$state_nl"
}

# 1. the running core: the host binaries (units or state/pid); the containers are removed below
echo "stopping the core ..."
for unit_file in "$host_systemd_path/$core_name"-*.service
do
  [ -e "$unit_file" ] || [ -L "$unit_file" ] || continue
  case "${unit_file##*/}" in
    "$core_name-recover.service")
      continue
  esac
  systemctl stop "${unit_file##*/}" > /dev/null 2>&1
done
if [ -e "$core_root/state/pid" ]
then
  coreStopBins "$core_root"
fi

# 2. containers: the core's of every version and the modules', with the images they use
echo "removing containers ..."
containers="$(
  docker ps -aq --filter "label=mgw_cid=$core_id"
  docker ps -aq --filter "label=com.docker.compose.project=$stack_name"
  docker ps -a --format '{{.ID}} {{.Label "com.docker.compose.project"}}' | while read -r ctr_id ctr_project
  do
    case "$ctr_project" in
      "${core_name}"_*)
        echo "$ctr_id"
    esac
  done
)"
containers="$(printf '%s\n' "$containers" | sort -u | grep -v '^$')"
module_images=""
for ctr in ${containers}
do
  ctr_image="$(docker inspect -f '{{.Config.Image}}' "$ctr" 2> /dev/null)"
  module_images="${module_images}$ctr_image$state_nl"
  # -v: also the container's anonymous volumes; the core's images have none (the compose file mounts
  # named volumes on every path they declare), but a module's image may
  docker rm -f -v "$ctr" > /dev/null 2>&1 || leftover "container $ctr"
done

# 3. images: the recorded core images and the images of the removed containers. An image a container
# outside the core still uses (e.g. another core on the same host) is kept: that is correct, not a
# failure, so it doesn't count as a leftover. Docker refuses to remove it either way (no -f).
echo "removing images ..."
for image in $({ imagesList "$core_root/state/images"; printf '%s' "$module_images"; } | sort -u | grep -v '^$')
do
  if docker image inspect "$image" > /dev/null 2>&1 && ! docker image rm "$image" > /dev/null 2>&1
  then
    if [ -n "$(docker ps -aq --filter "ancestor=$image" 2> /dev/null)" ]
    then
      echo "  kept: image $image, still used by another container"
      kept="${kept}  image $image$state_nl"
    else
      leftover "image $image"
    fi
  fi
done

# 4. volumes: the core's by name (checking mgw_cid where it is set) and the modules' by label
echo "removing volumes ..."
for volume in $(docker volume ls -q | grep "^${stack_name}_") $(docker volume ls -q --filter "label=mgw_cid=$core_id")
do
  volume_cid="$(docker volume inspect -f '{{index .Labels "mgw_cid"}}' "$volume" 2> /dev/null)"
  if [ "$volume_cid" != "" ] && [ "$volume_cid" != "$core_id" ]
  then
    leftover "volume $volume (belongs to the core $volume_cid)"
    continue
  fi
  objectsRemove "$core_root" "volume:$volume" 2> /dev/null || leftover "volume $volume"
done

# 5. networks
echo "removing networks ..."
for network in $(objectsNetworks | cut -d' ' -f1)
do
  objectsRemove "$core_root" "network:$network" 2> /dev/null || leftover "network $network"
done

# 6. and 7. systemd units and the links in /etc
echo "removing units and links ..."
objectsRemoveEtcLinks "$core_root" || leftover "links in /etc into $core_root/current/config"
mount_unit="$(systemd-escape --path --suffix=mount "/mnt/$core_name/secrets")"
for unit in "$core_name-recover.service" "$mount_unit"
do
  if [ -e "$host_systemd_path/$unit" ]
  then
    objectsRemove "$core_root" "unit:$unit" > /dev/null 2>&1
    objectsRemove "$core_root" "file:$host_systemd_path/$unit" || leftover "$host_systemd_path/$unit"
  fi
done
# links of ours whose names the current config doesn't know any more
for unit_file in "$host_systemd_path/$core_name"-*.service
do
  [ -L "$unit_file" ] || continue
  case "$(readlink "$unit_file")" in
    "$core_root"/*)
      objectsRemove "$core_root" "unit:${unit_file##*/}" > /dev/null 2>&1
      rm -f "$unit_file" || leftover "$unit_file"
  esac
done
if command -v systemctl > /dev/null 2>&1
then
  systemctl daemon-reload
  systemctl reset-failed > /dev/null 2>&1
fi
if [ -d "$host_avahi_path" ]
then
  systemctl reload avahi-daemon > /dev/null 2>&1 || avahi-daemon --reload > /dev/null 2>&1
fi

# 8. the secrets tmpfs
objectsRemove "$core_root" "mount:/mnt/$core_name/secrets" || leftover "the tmpfs /mnt/$core_name/secrets"
objectsRemove "$core_root" "dir:/mnt/$core_name" || leftover "/mnt/$core_name"

# 9. the core root, and 10. the update's working space
host_dir="$(settingsGet host_dir_repository_path)"
echo "removing $core_root ..."
lockRelease
objectsRemove "$core_root" "folder:." || leftover "$core_root"
objectsRemove "$core_root" "dir:/tmp/$core_name" || leftover "/tmp/$core_name"
case "$host_dir" in
  ""|"$core_root"/*)
    ;;
  *)
    echo "the module repository $host_dir is outside the core root and was left" >&2
esac

if [ "$kept" != "" ]
then
  echo "kept, still used by containers outside the core:"
  printf '%s' "$kept"
fi
if [ "$left" != "" ]
then
  echo "the core was removed, except:" >&2
  printf '%s' "$left" >&2
  exit 1
fi
echo "the core was removed"
