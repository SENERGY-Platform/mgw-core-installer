#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

if ! cd ${0%/*}
then
  exit 1
fi

script_path=$(pwd)
install_path=""
assume_yes=false
remove_images=false

printUsage() {
  printf '%s\n' \
  '' \
  "usage: $(basename $0) [-path=<install path>] [-y] [-i] [-h]" \
  '' \
  '-path   path of the core installation, defaults to the directory of this script' \
  '-y      remove without asking for confirmation' \
  '-i      also remove the container images of the core' \
  '-h      display this help page' \
  ''
}

handleParam() {
  key="${1%%=*}"
  val="${1##*=}"
  case "$key" in
  "-path")
    if [ "$val" != "" ] && [ "$val" != "$key" ]
    then
      install_path="$val"
    else
      echo "missing install path"
      exit 1
    fi
    ;;
  "-y")
    assume_yes=true
    ;;
  "-i")
    remove_images=true
    ;;
  "-h")
    printUsage
    exit 0
    ;;
  *)
    echo "unknown option '$1'"
    printUsage
    exit 1
  esac
}

checkRoot() {
  if ! isRoot
  then
    echo "root privileges required"
    exit 1
  fi
}

# the install directory is the only reliable inventory of what was installed,
# so a base path that would take half the file system with it is a broken
# .settings rather than something to work around
checkSettings() {
  case "$base_path" in
  "" | "/")
    echo "invalid base path in '$install_path/.settings'"
    exit 1
    ;;
  /*)
    ;;
  *)
    echo "base path must be absolute"
    exit 1
  esac
  if [ "$core_id" = "" ]
  then
    echo "missing core id in '$install_path/.settings'"
    exit 1
  fi
}

checkDocker() {
  if command -v docker > /dev/null 2>& 1
  then
    return 0
  fi
  echo "docker not found, skipping removal of containers, volumes and networks"
  return 1
}

handleConfirm() {
  printf '%s\n' \
  '' \
  "core id:       $core_id" \
  "core name:     $core_name" \
  "install path:  $base_path" \
  '' \
  'the following will be removed:' \
  '  the install directory and everything in it' \
  '  the secrets tmpfs and its mount point' \
  '  the systemd units, the logrotate config, the cronjob and the avahi service' \
  "  every container, volume and network of core '$core_id', deployed modules included"
  if [ "$remove_images" = "true" ]
  then
    echo '  the container images of the core'
  fi
  printf '%s\n' \
  ''
  if [ "$assume_yes" = "true" ]
  then
    return
  fi
  while :
  do
    printColor "uninstall multi-gateway core $core_id? (y/n): " "$blue" "nb"
    read -r choice
    case "$choice" in
    y)
      break
      ;;
    n)
      exit 0
      ;;
    *)
      echo "unknown option"
    esac
  done
}

# every resource the core owns is found by one of two labels: 'mgw_cid' is set
# by the compose file and by the module-manager, so it also covers the
# containers and volumes of deployed modules, while the compose project label
# covers the volumes and networks of the core stack, which carry no 'mgw_cid'.
# both are read from the engine instead of from the compose file, because an
# uninstall must also work on an installation whose container assets are gone
listResources() {
  {
    docker $1 ls -q $2 --filter "label=mgw_cid=$core_id"
    if [ "$stack_name" != "" ]
    then
      docker $1 ls -q $2 --filter "label=com.docker.compose.project=$stack_name"
    fi
  } | sort -u
}

handleContainers() {
  containers="$(listResources container -a)"
  if [ "$containers" = "" ]
  then
    echo "no containers to remove"
    return
  fi
  for container in ${containers}
  do
    echo "removing container $container ..."
    if ! docker container rm -f -v "$container" > /dev/null
    then
      exit 1
    fi
  done
}

handleVolumes() {
  volumes="$(listResources volume)"
  if [ "$volumes" = "" ]
  then
    echo "no volumes to remove"
    return
  fi
  for volume in ${volumes}
  do
    echo "removing volume $volume ..."
    if ! docker volume rm "$volume" > /dev/null
    then
      exit 1
    fi
  done
}

handleNetworks() {
  networks="$(listResources network)"
  if [ "$networks" = "" ]
  then
    echo "no networks to remove"
    return
  fi
  for network in ${networks}
  do
    echo "removing network $network ..."
    if ! docker network rm "$network" > /dev/null
    then
      echo "could not remove network $network"
    fi
  done
}

# only the images pinned in .options are known here, an image a module brought
# with it is not tracked anywhere. removing one that another core on the host
# still uses is refused by the engine, so a failure is reported and ignored
handleImages() {
  if [ "$remove_images" != "true" ]
  then
    return
  fi
  for item in ${images}
  do
    image="${item##*=}"
    echo "removing image $image ..."
    if ! docker image rm "$image" > /dev/null 2>& 1
    then
      echo "could not remove image $image"
    fi
  done
}

handleUnits() {
  if ! [ -e $base_path/.units ]
  then
    return
  fi
  installed_units="$(readFileToArray $base_path/.units)"
  for unit in ${installed_units}
  do
    echo "stopping $unit ..."
    if ! systemctl stop "$unit"
    then
      echo "could not stop $unit"
    fi
    echo "disabling $unit ..."
    if ! systemctl disable "$unit"
    then
      echo "could not disable $unit"
    fi
    if [ -e $systemd_path/$unit ]
    then
      echo "removing $unit ..."
      if ! rm $systemd_path/$unit
      then
        exit 1
      fi
    fi
    systemctl reset-failed "$unit" > /dev/null 2>& 1
  done
  echo "reloading systemd ..."
  if ! systemctl daemon-reload
  then
    exit 1
  fi
}

# without systemd integration the host binaries are the processes recorded in
# .pid, which is what stopBin works on
handleProcesses() {
  if [ -e $base_path/.units ]
  then
    return
  fi
  stopBin
}

# the mount unit takes the tmpfs with it when it is stopped, so this only has
# something to do without systemd integration or after a unit failed to stop
handleTmpfs() {
  unmountTmpfs
}

removeFile() {
  if [ -e "$1" ]
  then
    echo "removing $1 ..."
    if ! rm "$1"
    then
      exit 1
    fi
  fi
}

# the files are removed regardless of the logrotate, cron and advertise
# settings, a setting that was turned off after the installation would
# otherwise leave its file behind
handleIntegrationFiles() {
  removeFile "$logrotated_path/${core_name}_core"
  removeFile "$cron_path/${core_name}_update"
  removeFile "$avahi_path/${core_name}_core.service"
}

handleSecretsPath() {
  if [ "$secrets_path" = "" ] || ! [ -d "$secrets_path" ]
  then
    return
  fi
  path="$secrets_path"
  if [ "$core_name" != "" ] && [ "$path" = "/mnt/$core_name/secrets" ]
  then
    path="/mnt/$core_name"
  fi
  echo "removing $path ..."
  if ! rm -r "$path"
  then
    exit 1
  fi
}

handleWorkspaces() {
  rm -r /tmp/mgw-install > /dev/null 2>& 1
  rm -r /tmp/mgw-update > /dev/null 2>& 1
}

# a module repository outside the install directory was pointed at by the
# installation rather than created by it, so it is the user's to delete
handleExternalPaths() {
  case "$host_dir_repository_path" in
  "$base_path"/*)
    ;;
  "")
    ;;
  *)
    if [ -e "$host_dir_repository_path" ]
    then
      echo "host dir repository '$host_dir_repository_path' was kept"
    fi
  esac
}

# the script removes the directory it was started from when it runs as the
# installed copy, hence the move out of it
handleBasePath() {
  if ! cd /
  then
    exit 1
  fi
  echo "removing $base_path ..."
  if ! rm -r $base_path
  then
    exit 1
  fi
}

for param in "$@"
do
  handleParam "$param"
done

if [ "$install_path" = "" ]
then
  install_path="$script_path"
fi

if ! [ -e "$install_path/.settings" ]
then
  echo "no core installation found at '$install_path'"
  exit 1
fi

. $install_path/scripts/util.sh
. $install_path/scripts/settings.sh
. $install_path/.settings
if [ -e "$install_path/.options" ]
then
  . $install_path/.options
fi
. $install_path/scripts/bin_ctrl.sh

checkRoot
checkSettings
handleConfirm
printColor "removing container environment ..." "$yellow"
if checkDocker
then
  handleContainers
  handleVolumes
  handleNetworks
  handleImages
fi
printColor "removing container environment done" "$yellow"
printLnBr
printColor "removing integration ..." "$yellow"
handleUnits
handleProcesses
handleTmpfs
handleIntegrationFiles
printColor "removing integration done" "$yellow"
printLnBr
printColor "removing files ..." "$yellow"
handleSecretsPath
handleWorkspaces
handleExternalPaths
handleBasePath
printColor "removing files done" "$yellow"
printLnBr
printColor "uninstall successful" "$yellow"
printLnBr
