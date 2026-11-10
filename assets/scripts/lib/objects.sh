#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# The install record (state/install) and the objects of a core: creating them with "record first",
# and removing them (PLAN.md 10a, 10c).
#
# An install adds every object to state/install before it creates it, so whatever a killed install
# left behind is listed. Its cleanup removes exactly the listed objects in reverse order. The
# uninstall finds the objects by name and label instead, but removes them with the same functions.
# Every removal tolerates an object that doesn't exist.
#
# Objects, as written in state/install (created=<type>:<name>):
#   folder:<path>   a folder, relative to the core root ("." is the core root itself)
#   link:<path>     a symbolic link, relative to the core root (current)
#   file:<path>     a file, absolute (the core-owned unit files in /etc/systemd/system)
#   dir:<path>      a folder outside the core root, absolute (/mnt/<core_name>)
#   unit:<name>     an enabled systemd unit
#   mount:<path>    a tmpfs mounted without systemd
#   volume:<name>   a docker volume
#   network:<name>  a docker network
#   project:<name>  the containers of a compose project
#   etclinks:       the links in /etc into <core root>/current/config (created by the reconcile)
#
# Needs lib/file.sh, lib/state.sh, lib/host.sh, lib/settings.sh (loaded).

# state_* and the inst_ record come from lib/state.sh, host_* from lib/host.sh
# shellcheck disable=SC2154

# the record the create functions add to; empty when nothing is recorded (an update, restore)
objects_record=""

# --- the install record ---

# starts the record $1 of an install: writer $2 (version folder or the archive's version), mode $3
# (install or restore)
installRecordBegin() {
  recordClear inst "$state_install_fields" created
  recordSet inst format "$state_format"
  recordSet inst writer "$2"
  recordSet inst result running
  recordSet inst mode "$3"
  recordSet inst started "$(stateNow)"
  recordWrite "$1" inst "$state_install_fields" created
}

# loads the record $1 into the inst_ variables; return codes of recordLoad
installRecordLoad() {
  recordClear inst "$state_install_fields" created
  recordLoad "$1" inst created
}

# adds the object $2 (<type>:<name>) to the record $1 unless it is listed already. Returns 1 if the
# record couldn't be read or written: then the object must not be created. The record is read from
# the file each time, not kept in memory: a create function running in a subshell (e.g. at the end
# of a pipeline) adds to the file, and the next add must not write over it.
installRecordAdd() {
  if ! installRecordLoad "$1"
  then
    echo "cannot read '$1', not recording $2" >&2
    return 1
  fi
  if printf '%s\n' "$inst_created" | grep -qxF -- "$2"
  then
    return 0
  fi
  recordAppend inst created "$2"
  if ! recordWrite "$1" inst "$state_install_fields" created
  then
    echo "cannot record $2 in '$1'" >&2
    return 1
  fi
}

# records the result $2 (success or failed) in the record $1
installRecordResult() {
  installRecordLoad "$1" || return 1
  recordSet inst result "$2"
  recordSet inst finished "$(stateNow)"
  recordWrite "$1" inst "$state_install_fields" created
}

# --- creating ---

# adds $1 to objects_record if there is one; returns 1 if that fails
objectsRecord() {
  if [ "$objects_record" = "" ]
  then
    return 0
  fi
  installRecordAdd "$objects_record" "$1"
}

# creates the folder $2 (relative to the core root $1) with its parents if it doesn't exist
objectsFolder() {
  if [ -d "$1/$2" ]
  then
    return 0
  fi
  objectsRecord "folder:$2" || return 1
  mkdir -p "$1/$2"
}

# creates the folder $1 (absolute, outside the core root) with its parents if it doesn't exist
objectsDir() {
  if [ -d "$1" ]
  then
    return 0
  fi
  objectsRecord "dir:$1" || return 1
  mkdir -p "$1"
}

# writes stdin to the file $1 (absolute) with mode $2
objectsFile() {
  objectsRecord "file:$1" || return 1
  fileWriteAtomic "$1" "$2"
}

# creates the docker network $1 with the subnet $2 (address/prefix) for the core $3, if it doesn't
# exist. Bridge and attachable, as the compose file declared them before they became external (7).
objectsNetwork() {
  if docker network inspect "$1" > /dev/null 2>&1
  then
    return 0
  fi
  objectsRecord "network:$1" || return 1
  echo "creating network $1 ..."
  docker network create --driver bridge --attachable --subnet "$2" --label "mgw_cid=$3" "$1" > /dev/null
}

# creates the docker volume $1 for the core $2, if it doesn't exist
objectsVolume() {
  if docker volume inspect "$1" > /dev/null 2>&1
  then
    return 0
  fi
  objectsRecord "volume:$1" || return 1
  echo "creating volume $1 ..."
  docker volume create --label "mgw_cid=$2" "$1" > /dev/null
}

# prints the core's networks, one "<name> <subnet>/<prefix>" per line
objectsNetworks() {
  objects_cn="$(settingsGet core_name)"
  echo "$objects_cn-0-gateway-net $(settingsGet subnet_gateway)/28"
  echo "$objects_cn-1-core-net $(settingsGet subnet_core)/28"
  echo "$objects_cn-2-module-net $(settingsGet subnet_module)/16"
}

# --- removing ---

# removes the object $2 (<type>:<name>) of the core root $1. Returns 1 if it is still there.
objectsRemove() {
  objects_type="${2%%:*}"
  objects_name="${2#*:}"
  case "$objects_type" in
    folder|link)
      case "$objects_name" in
        ""|/*|..|../*|*/..|*/../*)
          echo "refusing to remove '$objects_name'" >&2
          return 1
      esac
      case "$1" in
        ""|/|[!/]*)
          echo "refusing to remove from the core root '$1'" >&2
          return 1
      esac
      if [ "$objects_name" = "." ]
      then
        rm -rf "$1"
      else
        rm -rf "${1:?}/$objects_name"
      fi
      ;;
    dir)
      case "$objects_name" in
        ""|/|*/..|*/../*|*/.|*/./*|[!/]*)
          echo "refusing to remove '$objects_name'" >&2
          return 1
      esac
      rm -rf "$objects_name"
      ;;
    file)
      case "$objects_name" in
        /?*)
          rm -f "$objects_name"
          ;;
        *)
          echo "refusing to remove '$objects_name'" >&2
          return 1
      esac
      ;;
    unit)
      systemctl stop "$objects_name" > /dev/null 2>&1
      systemctl disable "$objects_name" > /dev/null 2>&1
      systemctl reset-failed "$objects_name" > /dev/null 2>&1
      ! systemctl is-enabled --quiet "$objects_name" 2> /dev/null
      ;;
    mount)
      if mountpoint -q "$objects_name" 2> /dev/null
      then
        umount "$objects_name"
      fi
      ;;
    volume)
      if docker volume inspect "$objects_name" > /dev/null 2>&1
      then
        docker volume rm "$objects_name" > /dev/null
      fi
      ;;
    network)
      if docker network inspect "$objects_name" > /dev/null 2>&1
      then
        docker network rm "$objects_name" > /dev/null
      fi
      ;;
    project)
      objects_ctrs="$(docker ps -aq --filter "label=com.docker.compose.project=$objects_name")"
      if [ "$objects_ctrs" != "" ]
      then
        # shellcheck disable=SC2086 # one argument per container
        docker rm -f $objects_ctrs > /dev/null
      fi
      ;;
    etclinks)
      objectsRemoveEtcLinks "$1"
      ;;
    *)
      echo "unknown object '$2'" >&2
      return 1
  esac
}

# removes the links in the /etc folders that point into <core root $1>/current/config, disabling the
# units among them
objectsRemoveEtcLinks() {
  objects_rc=0
  for objects_dir in "$host_systemd_path" "$host_logrotated_path" "$host_cron_path" "$host_avahi_path"
  do
    for objects_link in "$objects_dir"/*
    do
      if ! [ -L "$objects_link" ]
      then
        continue
      fi
      case "$(readlink "$objects_link")" in
        "$1/current/config/"*)
          ;;
        *)
          continue
      esac
      if [ "$objects_dir" = "$host_systemd_path" ]
      then
        systemctl stop "${objects_link##*/}" > /dev/null 2>&1
        systemctl disable "${objects_link##*/}" > /dev/null 2>&1
        find "$host_systemd_path" -mindepth 2 -maxdepth 2 -type l -name "${objects_link##*/}" -delete
      fi
      rm -f "$objects_link" || objects_rc=1
    done
  done
  return $objects_rc
}

# removes the images listed in the images file $1 that no container uses; docker refuses the others
objectsRemoveImages() {
  imagesList "$1" | while IFS= read -r objects_image
  do
    if docker image rm "$objects_image" > /dev/null 2>&1
    then
      imagesRemove "$1" "$objects_image"
    fi
  done
}

# --- the install's cleanup ---

# removes everything the install recorded in $2 (state/install of the core root $1), in reverse
# order, then the images it pulled. If something can't be removed, the core root is kept, with the
# record at failed listing exactly what is left; otherwise the core root goes, record included.
installCleanup() {
  if ! installRecordLoad "$2"
  then
    echo "cannot read '$2'" >&2
    return 1
  fi
  install_left=""
  install_root_listed=false
  install_systemd=false
  install_objects="$(printf '%s\n' "$inst_created" | sed '1!G;h;$!d')"
  for install_object in ${install_objects}
  do
    if [ "$install_object" = "folder:." ]
    then
      install_root_listed=true
      continue
    fi
    case "$install_object" in
      unit:*|file:"$host_systemd_path"/*|etclinks:*)
        install_systemd=true
    esac
    if ! objectsRemove "$1" "$install_object"
    then
      echo "could not remove $install_object" >&2
      install_left="$install_object${install_left:+$state_nl$install_left}"
    fi
  done
  if [ "$install_systemd" = "true" ]
  then
    systemctl daemon-reload 2> /dev/null
  fi
  if [ -e "$1/state/images" ]
  then
    objectsRemoveImages "$1/state/images"
  fi
  if [ "$install_left" != "" ]
  then
    if [ "$install_root_listed" = "true" ]
    then
      install_left="folder:.$state_nl$install_left"
    fi
    inst_created="$install_left"
    recordSet inst result failed
    recordSet inst finished "$(stateNow)"
    recordWrite "$2" inst "$state_install_fields" created
    return 1
  fi
  if [ "$install_root_listed" = "true" ]
  then
    objectsRemove "$1" "folder:."
    return
  fi
  installRecordResult "$2" failed
}
