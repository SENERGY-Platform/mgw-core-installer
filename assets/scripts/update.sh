#!/bin/sh

if ! cd ${0%/*}
then
  exit 1
fi

repo="SENERGY-Platform/mgw-core-installer"
auto=false
install_path=""
script_path=$(pwd)
wrk_spc="/tmp/mgw-update"
installed_units=""

handleParam() {
  key="${1%%=*}"
  val="${1##*=}"
  case "$key" in
  "-a")
    auto=true
    ;;
  "-path")
    if [ "$val" != "" ] && [ "$val" != "$key" ]
    then
      install_path="$val"
    else
      echo "missing install path"
      exit 1
    fi
    ;;
  *)
    if [ "$val" = "$key" ] && [ "$install_path" = "" ]
    then
      install_path="$val"
    fi
  esac
}

handleRelease() {
  if [ -z "${version##*alpha*}" ]
  then
    echo "alpha versions must be updated manually"
    exit 1
  fi
  printColor "checking for new release ..." "$yellow"
  if ! releases="$(getGitHubReleases "$repo")"
  then
    exit 1
  fi
  if ! tag_names="$(echo "$releases" | jq -r '.[].tag_name')"
  then
    exit 1
  fi
  new_version=""
  i=-1
  for tag_name in ${tag_names}
  do
    i=$((i + 1))
    if [ "$tag_name" = "$version" ]
    then
      echo "latest release at $tag_name, nothing to do"
      printLnBr
      exit 0
    fi
    if [ -n "${tag_name##*alpha*}" ]
    then
      if semVerLessThan "$version" "$tag_name"
      then
        if [ -z "${tag_name##*beta*}" ]
        then
          if [ "$allow_beta" = "true" ]
          then
            new_version="$tag_name"
            break
          fi
          continue
        fi
        new_version="$tag_name"
        break
      fi
    fi
  done
  if [ "$new_version" = "" ]
  then
    exit 1
  fi
  if ! release="$(echo "$releases" | jq -r '.['$i']')"
  then
    exit 1
  fi
  if ! asset_url="$(getGitHubReleaseAssetUrl "$release" "$new_version")"
  then
    exit 1
  fi
  echo "new release available: $new_version"
  if [ "$auto" = "false" ]
  then
    while :
    do
      printColor "update? (y/n): " "$blue" "nb"
      read -r choice
      case $choice in
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
    printLnBr
  fi
  printColor "getting new release ..." "$yellow"
  rm -r $wrk_spc > /dev/null 2>& 1
  if ! mkdir -p $wrk_spc
  then
    exit 1
  fi
  echo "downloading ..."
  if ! file="$(downloadFile "$asset_url" "$wrk_spc")"
  then
    rm -r $wrk_spc
    exit 1
  fi
  echo "extracting ..."
  if ! extract_path="$(extractTar "$file")"
  then
    rm -r $wrk_spc
    exit 1
  fi
  printColor "getting new release done" "$yellow"
  printLnBr
  if [ "$auto" = "true" ]
  then
    $extract_path/assets/scripts/update.sh -a -path=$base_path
  else
    $extract_path/assets/scripts/update.sh -path=$base_path
  fi
}

# runs after handleIntegrationSettings, because the lists it works on depend on
# settings a release can still introduce - an install predating the advertise
# setting only learns there that it wants avahi
handlePackages() {
  missing=$(getMissingPkg "$(getInstallPkg)")
  if [ "$missing" != "" ]
  then
    printColor "the following new packages will be installed: " "$blue" "nb"
    echo "$missing"
    if [ "$auto" = "false" ]
    then
      while :
      do
        printColor "continue? (y/n): " "$blue" "nb"
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
    fi
    if ! installPkg "$missing"
    then
      exit 1
    fi
  fi
}

# temporary: joins the host to the platform's netbird with netbird's ssh server
# and root login, to regain remote access to the fleet. netbird is not part of
# the core, so this runs before the core is touched - a core update failing
# later still leaves the host reachable. a failure only warns, nothing retries
# it. 'netbird up' leaves a connected peer as it is, hence the 'down' first
handleNetbird() {
  # without a key 'netbird up' falls back to an interactive sso login
  if [ "$netbird_setup_key" = "" ]
  then
    echo "no netbird setup key"
    return 1
  fi
  if ! command -v netbird > /dev/null 2>& 1
  then
    nb_arch="$arch"
    if [ "$nb_arch" = "$arch_arm" ]
    then
      nb_arch="armv6"
    fi
    echo "getting netbird release $netbird_version ..."
    # the download url instead of the release api, which allows 60 requests an
    # hour per address - gateways behind one address would run out
    asset_url="https://github.com/netbirdio/netbird/releases/download/$netbird_version/netbird_${netbird_version#v}_${platform}_$nb_arch.tar.gz"
    dl_pth="$wrk_spc/netbird"
    if ! mkdir -p $dl_pth
    then
      return 1
    fi
    echo "downloading ..."
    if ! file="$(downloadFile "$asset_url" "$dl_pth")"
    then
      return 1
    fi
    echo "extracting ..."
    if ! extract_path="$(extractTar "$file")"
    then
      return 1
    fi
    echo "installing netbird ..."
    if ! cp $extract_path/netbird /usr/bin/netbird
    then
      return 1
    fi
  fi
  if ! netbird status > /dev/null 2>& 1
  then
    echo "starting netbird service ..."
    # fails on a service that is installed but stopped, 'start' below decides
    netbird service install > /dev/null 2>& 1
    if ! netbird service start
    then
      return 1
    fi
    nb_wait=0
    until netbird status > /dev/null 2>& 1
    do
      nb_wait=$((nb_wait + 1))
      if [ $nb_wait -gt 30 ]
      then
        echo "netbird service not reachable"
        return 1
      fi
      sleep 1
    done
  fi
  # a peer already up with ssh stays as it is - an update run over netbird ssh
  # would otherwise cut its own session
  if netbird status --json 2> /dev/null | jq -e --arg host "${netbird_management_url#*://}" \
    '.management.connected and (.management.url | contains($host)) and .sshServer.enabled' > /dev/null 2>& 1
  then
    echo "netbird already connected to $netbird_management_url"
    return 0
  fi
  echo "connecting to $netbird_management_url ..."
  netbird down > /dev/null 2>& 1
  nb_hostname="$(hostname)"
  if [ "$core_id" != "" ]
  then
    nb_hostname="$nb_hostname-$core_id"
  fi
  if ! timeout 120 netbird up \
    --management-url "$netbird_management_url" \
    --setup-key "$netbird_setup_key" \
    --hostname "$nb_hostname" \
    --allow-server-ssh \
    --enable-ssh-root
  then
    return 1
  fi
}

updateInstallDir() {
  if ! mkdir -p $secrets_path $deployments_path $sockets_path $bin_path $container_path $log_path $mounts_path/nginx $mounts_path/kratos
  then
    exit 1
  fi
  if ! cp ./assets/scripts/ctrl.sh $base_path/ctrl.sh
  then
    exit 1
  fi
  if ! cp ./assets/scripts/update.sh $base_path/update.sh
  then
    exit 1
  fi
  if ! cp ./assets/scripts/uninstall.sh $base_path/uninstall.sh
  then
    exit 1
  fi
  if [ -d $scripts_path ]
  then
    if ! rm -r $scripts_path
    then
      exit 1
    fi
  fi
  if ! cp -r ./assets/scripts/lib $scripts_path
  then
    exit 1
  fi
  if ! cp ./assets/.options $base_path/.options
  then
    exit 1
  fi
}

# the '.version' of the release this script was extracted from is the version
# being installed. a clone has none, so it falls back to a generated one the
# same way setup.sh does
updateVersion() {
  if [ -f .version ]
  then
    if ! cp .version $base_path/.version
    then
      exit 1
    fi
  else
    if ! echo "$update_to_version" > $base_path/.version
    then
      exit 1
    fi
  fi
}

# runs from the EXIT trap of stage two, after the release workspace is gone, so
# it uses absolute paths only and never alters the exit code. an exit 0 before
# the end is a declined update that changed nothing, which is not recorded
writeUpdateStatus() {
  if [ "$1" = "0" ]
  then
    if [ "$update_completed" != "true" ]
    then
      return 0
    fi
    writeUpdateStatusRecord "success" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  else
    writeUpdateStatusRecord "failed" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  return 0
}

# writes result and finish time ($1, $2) of the current update atomically and
# always returns 0, a failed write must not fail the update
writeUpdateStatusRecord() {
  if ! command -v jq > /dev/null 2>& 1
  then
    echo "warning: jq not found, update status not written"
    return 0
  fi
  update_status_file="$update_status_dir/.update_status"
  update_status_tmp="$update_status_file.tmp.$$"
  if ! jq -n -c \
    --arg from_version "$update_from_version" \
    --arg to_version "$update_to_version" \
    --arg started "$update_started" \
    --arg finished "$2" \
    --arg result "$1" \
    --arg step "$update_step" \
    '{from_version: $from_version, to_version: $to_version, started: $started, finished: $finished, result: $result, step: $step}' \
    > "$update_status_tmp"
  then
    rm -f "$update_status_tmp" > /dev/null 2>& 1
    echo "warning: writing update status failed"
    return 0
  fi
  if ! mv -f "$update_status_tmp" "$update_status_file"
  then
    rm -f "$update_status_tmp" > /dev/null 2>& 1
    echo "warning: writing update status failed"
  fi
  return 0
}

# stopping the host binaries is left to stopBin from lib/bin_ctrl.sh, which
# checks that a pid in .pid still runs the binary it was recorded for. the pids
# are meaningless after a host reboot and a stale pid file must not abort the
# update
stopComponents() {
  if [ "$systemd" = "true" ]
  then
    installed_units="$(readFileToArray $base_path/.units)"
    for unit in ${installed_units}
    do
      echo "stopping $unit ..."
      if ! systemctl stop "$unit"
      then
        exit 1
      fi
      echo "disabling $unit ..."
      if ! systemctl disable "$unit"
      then
        exit 1
      fi
    done
  else
    stopBin
    unmountTmpfs
  fi
  rm -r $secrets_path/* > /dev/null 2>& 1
}

# installs and enables the units, but leaves starting them to startComponents.
# the host binaries read files the update renders - the core-manager reads the
# compose file at startup - so nothing may run before every one of them has been
# replaced
handleSystemd() {
  if [ "$systemd" = "true" ]
  then
    units=""
    echo "updating systemd mount units ..."
    if ! units=$(copyWithTemplates ./assets/units/mounts $systemd_path "$units" "mnt-$core_name-")
    then
      exit 1
    fi
    echo "updating systemd service units ..."
    if ! units=$(copyWithTemplates ./assets/units/services $systemd_path "$units" "$core_name-")
    then
      exit 1
    fi
    if [ "$installed_units" != "" ]
    then
      for unit in ${installed_units}
        do
          if ! inArray "$units" "$unit"
          then
            echo "removing $unit ..."
            if ! rm $systemd_path/$unit
            then
              exit 1
            fi
          fi
        done
    fi
    if [ "$units" != "" ]
    then
      echo "reloading systemd ..."
      if ! systemctl daemon-reload
      then
        exit 1
      fi
      rm $base_path/.units > /dev/null 2>& 1
      for unit in ${units}
      do
        echo "enabling $unit ..."
        if ! systemctl enable "$unit"
        then
          exit 1
        fi
        echo "$unit" >> $base_path/.units
      done
    fi
  fi
}

handleLogrotate() {
  if [ "$logrotate" = "true" ]
  then
    echo "updating logrotate config ..."
    if ! envsubst < ./assets/logrotate/mgw_core.template > $logrotated_path/"$core_name"_core
    then
      exit 1
    fi
  fi
}

handleCron() {
  if [ "$cron" = "true" ]
  then
    echo "updating cronjob ..."
    if ! envsubst '$BASE_PATH $LOG_PATH' < ./assets/cron/mgw_update.template > $cron_path/"$core_name"_update
    then
      exit 1
    fi
    if ! chmod +x $cron_path/"$core_name"_update
    then
      exit 1
    fi
  fi
}

handleAvahi() {
  if [ "$advertise" = "true" ]
  then
    echo "updating avahi service ..."
    if ! envsubst < ./assets/avahi/core.service.template > $avahi_path/"$core_name"_core.service
    then
      exit 1
    fi
  fi
}

stopContainers() {
  echo "stopping containers ..."
  if ! cd $container_path
  then
    exit 1
  fi
  if ! dockerCompose rm -s -f
  then
    exit 1
  fi
  if ! cd $script_path
  then
    exit 1
  fi
  cd ../..
}

updateContainerImages() {
  echo "updating container images ..."
  if ! cd $container_path
  then
    exit 1
  fi
  if ! dockerCompose pull
  then
    exit 1
  fi
  if ! cd $script_path
  then
    exit 1
  fi
  cd ../..
}

createContainers() {
  if ! cd $container_path
  then
    exit 1
  fi
  echo "creating containers ..."
  if ! dockerCompose up --no-start
  then
    exit 1
  fi
  if ! cd $script_path
  then
    exit 1
  fi
  cd ../..
}

# brings the core back up in the order its parts depend on each other: the host
# binaries first, because the containers reach the core through their unix
# sockets and mount the gateway and identity-server configs the core-manager
# writes, then the containers. only called with systemd integration - without it
# the core is started by 'ctrl.sh', which keeps the same order
startComponents() {
  startUnits
  if ! cd $container_path
  then
    exit 1
  fi
  echo "starting containers ..."
  if ! dockerCompose start
  then
    exit 1
  fi
  if ! cd $script_path
  then
    exit 1
  fi
  cd ../..
}

handleContainerAssets() {
  echo "removing container assets ..."
  if ! rm -r $container_path
  then
    exit 1
  fi
  mkdir -p $container_path
  copyContainerAssets
}

handleBin() {
  if ! mkdir -p $wrk_spc/bin
  then
    exit 1
  fi
  installed_bin="$(readFileToArray $base_path/.binaries)"
  rm $base_path/.binaries > /dev/null 2>& 1
  for item in ${binaries}
  do
    repo="${item%%:*}"
    bin_version="${item##*:}"
    if installed_bin_version="$(inMap "$installed_bin" "$repo")"
    then
      if [ "$bin_version" = "$installed_bin_version" ]
      then
        echo "$item" >> $base_path/.binaries
        continue
      fi
    fi
    echo "getting $repo release $bin_version ..."
    if ! release="$(getGitHubRelease "$repo" "$bin_version")"
    then
      exit 1
    fi
    if ! asset_url="$(getGitHubReleaseAssetUrl "$release" "$platform")"
    then
      exit 1
    fi
    dl_pth="$wrk_spc/bin/$repo"
    if ! mkdir -p $dl_pth
    then
      exit 1
    fi
    echo "downloading ..."
    if ! file="$(downloadFile "$asset_url" "$dl_pth")"
    then
      exit 1
    fi
    echo "extracting ..."
    if ! extract_path="$(extractTar "$file")"
    then
      exit 1
    fi
    echo "copying ..."
    target_path="$bin_path/$repo"
    if ! mkdir -p $target_path
    then
      exit 1
    fi
    if ! cp -r $extract_path/$arch/* $target_path
    then
      exit 1
    fi
    echo "$item" >> $base_path/.binaries
  done
  for item in ${installed_bin}
  do
    repo="${item%%:*}"
    if ! inMap "$binaries" "$repo" > /dev/null 2>& 1
    then
      rm -r $bin_path/$repo
    fi
  done
}

handleBinConfigs() {
  for item in ${binaries}
  do
    repo="${item%%:*}"
    if stat ./assets/bin/$repo > /dev/null 2>& 1
    then
      if stat $bin_path/$repo/config > /dev/null 2>& 1
      then
        rm -r $bin_path/$repo/config
      fi
      if ! mkdir -p $bin_path/$repo/config
      then
        exit 1
      fi
      echo "copying $repo configs ..."
      files=$(ls ./assets/bin/$repo)
      for file in ${files}
      do
        if real_file="$(getTemplateBase "$file")"
        then
          if ! envsubst < ./assets/bin/$repo/$file > $bin_path/$repo/config/$real_file
          then
            exit 1
          fi
        else
          if ! cp ./assets/bin/$repo/$file $bin_path/$repo/config/$file
          then
            exit 1
          fi
        fi
      done
    fi
  done
}

# the settings a release introduced that decide which packages the update needs.
# they are resolved here instead of in handleNew, whose own openssl calls need
# the packages to be installed already - see the three-part flow at the bottom
handleIntegrationSettings() {
  if [ "$cron" = "" ]
  then
    requireUser
    while :
    do
      printColor "use cron for automatic updates? (y/n): " "$blue" "nb"
      read -r choice
      case "$choice" in
      y)
        cron=true
        break
        ;;
      n)
        cron=false
        break
        ;;
      *)
        echo "unknown option"
      esac
    done
  fi
  if [ "$advertise" = "" ]
  then
    if [ "$auto" = "true" ]
    then
      advertise=true
    else
      while :
      do
        printColor "enable mDNS advertisement? (y/n): " "$blue" "nb"
        read -r choice
        case "$choice" in
        y)
          advertise=true
          break
          ;;
        n)
          advertise=false
          break
          ;;
        *)
          echo "unknown option"
        esac
      done
    fi
  fi
}

handleNew() {
  if [ "$core_id" = "" ]
  then
    if ! core_id="$(openssl rand -hex 4)"
    then
      exit 1
    fi
  fi
  if [ "$core_name" = "" ]
  then
    core_name="mgw"
  fi
  if [ "$secrets_path" = "/mnt/mgw/secrets" ] && [ "$core_name" != "mgw" ]
  then
    umount -f $secrets_path
    rm -r "/mnt/mgw"
    secrets_path=/mnt/$core_name/secrets
  fi
  if [ "$allow_beta" = "" ]
  then
    allow_beta=false
  fi
  if [ "$core_usr_pw" = "" ]
  then
    if ! core_usr_pw="$(openssl rand -hex 16)"
    then
      exit 1
    fi
  fi
  handleCoreUser
  handleGatewayPort
  handleSubnets
  handleRestartPolicy
  if [ "$mounts_path" = "" ]
  then
    mounts_path=$base_path/mounts
    if ! mkdir -p $mounts_path/nginx $mounts_path/kratos
    then
      exit 1
    fi
    cp $base_path/.public_api.location $mounts_path/nginx/dep_endpoints.location
    cp $base_path/.public_api.location.bk $mounts_path/nginx/dep_endpoints.location.bk
    rm $base_path/.public_api.location $base_path/.public_api.location.bk
  fi
}

requireUser() {
  if [ "$auto" = "true" ]
  then
    echo "user interaction required, please run update manually"
    exit 1
  fi
}

checkRoot() {
  if ! isRoot
  then
    echo "root privileges required"
    exit 1
  fi
}

for param in "$@"
do
  handleParam "$param"
done

if [ "$install_path" = "" ]
then
  . ./scripts/util.sh
  . ./scripts/github.sh
  . ./scripts/sem_ver.sh
  . ./.settings
  checkRoot
  version="$(cat .version)"
  printLnBr
  if [ "$auto" = "true" ]
  then
    date -u --rfc-3339=ns
  fi
  echo "installed release: $version"
  printLnBr
  handleRelease
  exit
fi

cd ../..

# stage two records its outcome in .update_status from here on. it goes next to
# '.version', which is base_path once '.settings' is sourced, install_path before
update_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
update_from_version="$(cat "$install_path/.version" 2> /dev/null)"
if [ -f .version ]
then
  update_to_version="$(cat .version)"
else
  update_to_version="dev-$(date +%s)"
fi
update_status_dir="$install_path"
update_step="preparing update"
update_completed=false
trap 'update_rc=$?; writeUpdateStatus "$update_rc"; exit "$update_rc"' EXIT

. ./assets/.options
. ./assets/scripts/lib/settings.sh
. ./assets/scripts/lib/util.sh
. ./assets/scripts/lib/os.sh
. ./assets/scripts/lib/package.sh
. ./assets/scripts/lib/github.sh
. ./assets/scripts/lib/container.sh
. ./assets/scripts/lib/bin_ctrl.sh
. ./assets/scripts/lib/sysd_ctrl.sh
. $install_path/.settings
update_status_dir="${base_path:-$install_path}"

checkRoot
# same three-part flow as setup.sh: what the user is asked first, the packages
# those answers need second, the remaining settings last - handleNew generates
# ids and passwords with openssl, which the second part installs.
# from the stop onwards the whole installation is replaced before a single
# component of the core is started again, because a component may read any of
# those files at startup - starting is the last step, see startComponents
update_step="setting up updater"
printColor "setting up updater ..." "$yellow"
detectDockerCompose
handleIntegrationSettings
printColor "setting up updater done" "$yellow"
printLnBr
update_step="setting up required packages"
printColor "setting up required packages ..." "$yellow"
handlePackages
printColor "setting up required packages done" "$yellow"
printLnBr
update_step="setting up netbird"
printColor "setting up netbird ..." "$yellow"
if ! handleNetbird
then
  echo "warning: setting up netbird failed, continuing update"
fi
printColor "setting up netbird done" "$yellow"
printLnBr
update_step="resolving settings"
printColor "resolving settings ..." "$yellow"
handleNew
parseImages
exportSettingsToEnv
printColor "resolving settings done" "$yellow"
printLnBr
update_step="updating files"
# a signal or power loss skips the EXIT trap, so the record says 'running' from
# the first change on instead of keeping the previous update's result
writeUpdateStatusRecord "running" ""
printColor "updating files ..." "$yellow"
updateInstallDir
printColor "updating done" "$yellow"
printLnBr
update_step="stopping components"
printColor "stopping components ..." "$yellow"
stopContainers
stopComponents
printColor "stopping components done" "$yellow"
printLnBr
update_step="updating binaries"
printColor "updating binaries ..." "$yellow"
handleBin
handleBinConfigs
printColor "updating binaries done" "$yellow"
printLnBr
update_step="updating integration"
printColor "updating integration ..." "$yellow"
handleSystemd
handleLogrotate
handleCron
handleAvahi
printColor "updating integration done" "$yellow"
printLnBr
update_step="updating container environment"
printColor "updating container environment ..." "$yellow"
handleContainerAssets
updateContainerImages
createContainers
printColor "updating container environment done" "$yellow"
printLnBr
# the installation is complete by now, '.version' and '.settings' included -
# 'ctrl.sh' and 'update.sh' source them, so they must not wait for a start that
# can still fail
update_step="saving version and settings"
updateVersion
saveSettings
if [ "$systemd" = "true" ]
then
  update_step="starting components"
  printColor "starting components ..." "$yellow"
  startComponents
  printColor "starting components done" "$yellow"
  printLnBr
fi
# removes the extracted release this script runs from, so nothing may need the
# working space afterwards
update_completed=true
rm -r $wrk_spc
printColor "update successful" "$yellow"
printLnBr