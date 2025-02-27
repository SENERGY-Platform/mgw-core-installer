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

handlePackages() {
  missing=$(getMissingPkg "$install_pkg")
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

updateInstallDir() {
  if ! mkdir -p $secrets_path $deployments_path $sockets_path $bin_path $container_path $log_path $scripts_path $mounts_path/nginx $mounts_path/kratos
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
  if ! cp ./assets/scripts/lib/util.sh $base_path/scripts/util.sh
  then
    exit 1
  fi
  if ! cp ./assets/scripts/lib/github.sh $base_path/scripts/github.sh
  then
    exit 1
  fi
  if ! cp ./assets/scripts/lib/docker.sh $base_path/scripts/docker.sh
  then
    exit 1
  fi
  if ! cp ./assets/scripts/lib/bin_ctrl.sh $base_path/scripts/bin_ctrl.sh
  then
    exit 1
  fi
  if ! cp ./assets/scripts/lib/sysd_ctrl.sh $base_path/scripts/sysd_ctrl.sh
  then
    exit 1
  fi
  if ! cp ./assets/scripts/lib/ctr_ctrl.sh $base_path/scripts/ctr_ctrl.sh
  then
    exit 1
  fi
  if ! cp ./assets/scripts/lib/sem_ver.sh $base_path/scripts/sem_ver.sh
  then
    exit 1
  fi
  if ! cp ./assets/scripts/lib/settings.sh $base_path/scripts/settings.sh
  then
    exit 1
  fi
}

updateVersion() {
  if ! cp .version $base_path/.version
  then
    exit 1
  fi
}

stopBin() {
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
    if stat $base_path/.pid > /dev/null 2>& 1
    then
      pids="$(cat $base_path/.pid)"
      echo "stopping processes ..."
      for pid in ${pids}
      do
        if ! kill $pid
        then
          exit 1
        fi
      done
      if ! rm $base_path/.pid
      then
        exit 1
      fi
      echo "unmounting secrets tmpfs ..."
      umount -f $secrets_path
    fi
  fi
  rm -r $secrets_path/* > /dev/null 2>& 1
}

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
        echo "starting $unit ..."
        if ! systemctl start "$unit"
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

handleMigration() {
  if ! docker volume inspect "$stack_name"_mysqldb-data > /dev/null 2>& 1
  then
    echo "migrating database ..."
    if ! envsubst < ./assets/container/migrate.yml.template > ./assets/container/migrate.yml
    then
      exit 1
    fi
    if ! dockerCompose -f ./assets/container/migrate.yml up -d
    then
      exit 1
    fi
    echo "waiting 120s for database init ..."
    sleep 120
    if ! docker container exec -it "$core_name-db1" sh -c  "mysqldump -u root --password=$core_db_root_pw --databases module_manager secret_manager > db_dump.sql"
    then
      exit 1
    fi
    if ! docker container exec -it "$core_name-db1" sh -c "mysql -h $core_name-db2 -u root --password=$core_db_root_pw < db_dump.sql"
    then
      exit 1
    fi
    if ! dockerCompose -f ./assets/container/migrate.yml rm -s -f
    then
      exit 1
    fi
    rm ./assets/container/migrate.yml
  fi
}

handleGatewayNet() {
  if docker network inspect "$core_name-0-gateway-net" | grep -q "/29"
  then
    echo "removing $core_name-0-gateway-net ..."
    if ! docker network rm "$core_name-0-gateway-net"
    then
      exit 1
    fi
  fi
}

handleContainers() {
  if ! cd $container_path
  then
    exit 1
  fi
  echo "creating containers ..."
  if ! dockerCompose up --no-start
  then
    exit 1
  fi
  if [ "$systemd" = "true" ]
  then
    echo "starting containers ..."
    if ! dockerCompose start
    then
      exit 1
    fi
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
    new_version="${item##*:}"
    if version="$(inMap "$installed_bin" "$repo")"
    then
      if [ "$new_version" = "$version" ]
      then
        echo "$item" >> $base_path/.binaries
        continue
      fi
    fi
    echo "getting $repo release $new_version ..."
    if ! release="$(getGitHubRelease "$repo" "$new_version")"
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

handleNew() {
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
  if [ "$advertise" = "" ]
  then
    advertise=true
  fi
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

. ./assets/.options
. ./assets/scripts/lib/settings.sh
. ./assets/scripts/lib/util.sh
. ./assets/scripts/lib/os.sh
. ./assets/scripts/lib/package.sh
. ./assets/scripts/lib/github.sh
. ./assets/scripts/lib/docker.sh
. ./assets/scripts/lib/container.sh
. $install_path/.settings

checkRoot
printColor "setting up required packages ..." "$yellow"
handlePackages
printColor "setting up required packages done" "$yellow"
printLnBr
printColor "setting up updater ..." "$yellow"
detectDockerCompose
handleNew
parseImages
exportSettingsToEnv
printColor "setting up updater done" "$yellow"
printLnBr
printColor "updating files ..." "$yellow"
updateInstallDir
printColor "updating done" "$yellow"
printLnBr
printColor "stopping components ..." "$yellow"
stopContainers
stopBin
printColor "stopping components done" "$yellow"
printLnBr
printColor "updating binaries ..." "$yellow"
handleBin
handleBinConfigs
printColor "updating binaries done" "$yellow"
printLnBr
printColor "updating integration ..." "$yellow"
handleSystemd
handleLogrotate
handleCron
handleAvahi
printColor "updating integration done" "$yellow"
printLnBr
printColor "updating container environment ..." "$yellow"
handleContainerAssets
updateContainerImages
handleMigration
handleGatewayNet
handleContainers
printColor "updating container environment done" "$yellow"
updateVersion
saveSettings
rm -r $wrk_spc
printLnBr
printColor "update successful" "$yellow"
printLnBr