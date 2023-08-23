#!/bin/sh

script_path=${0%/*}
if ! cd $script_path
then
  exit 1
fi

repo="SENERGY-Platform/mgw-core-installer"
install_path=$1
wrk_spc="/tmp/mgw-update"
installed_units=""

handleRelease() {
  printf "\e[93;1mchecking for new release ...\e[0m\n"
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
    echo
    printf "\e[93;1mgetting new release ...\e[0m\n"
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
    printf "\e[93;1mgetting new release done\e[0m\n"
    echo
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

updateInstallDir() {
  if ! mkdir -p $secrets_path $deployments_path $sockets_path $bin_path $container_path $log_path $scripts_path
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
      echo "unmounting secrets tmpfs ..."
      if ! umount $secrets_path
      then
        exit 1
      fi
    fi
  fi
}

handleSystemd() {
  if [ "$systemd" = "true" ]
  then
    units=""
    echo "updating systemd mount units ..."
    if ! units=$(copyWithTemplates ./assets/units/mounts $systemd_path "$units")
    then
      exit 1
    fi
    echo "updating systemd service units ..."
    if ! units=$(copyWithTemplates ./assets/units/services $systemd_path "$units")
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
    if ! envsubst < ./assets/logrotate/mgw_core.template > $logrotated_path/mgw_core
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
  if ! docker compose stop
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
  if ! docker compose pull
  then
    exit 1
  fi
  if ! cd $script_path
  then
    exit 1
  fi
  cd ../..
}

startContainers() {
  echo "starting containers ..."
  if ! cd $container_path
  then
    exit 1
  fi
  if ! docker compose up -d
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
        continue
      fi
    fi
    echo "getting $repo release $version ..."
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
      rm -r "$wrk_spc"
    fi
    echo "$item" >> $base_path/.binaries
  done
  for item in ${installed_bin}
  do
    repo="${item%%:*}"
    if ! inMap "$binaries" "$repo"
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
      if ! mkdir -p $bin_path/$repo/config
      then
        exit 1
      fi
      rm -r $bin_path/$repo/config/*
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

checkRoot() {
  if ! isRoot
  then
    echo "root privileges required"
    exit 1
  fi
}

if [ "$install_path" = "" ]
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

. ./assets/.options
. ./assets/scripts/lib/settings.sh
. ./assets/scripts/lib/util.sh
. ./assets/scripts/lib/os.sh
. ./assets/scripts/lib/package.sh
. ./assets/scripts/lib/github.sh
. ./assets/scripts/lib/docker.sh
. $install_path/.settings

checkRoot
printf "\e[93;1msetting up updater ...\e[0m\n"
exportSettingsToEnv
printf "\e[93;1msetting up updater done\e[0m\n"
echo
printf "\e[93;1msetting up required packages ...\e[0m\n"
handlePackages
printf "\e[93;1msetting up required packages done\e[0m\n"
echo
printf "\e[93;1mupdating files ...\e[0m\n"
updateInstallDir
printf "\e[93;1mupdating done\e[0m\n"
echo
printf "\e[93;1mstopping components ...\e[0m\n"
stopContainers
stopBin
printf "\e[93;1mstopping components done\e[0m\n"
echo
printf "\e[93;1mupdating binaries ...\e[0m\n"
handleBin
handleBinConfigs
printf "\e[93;1mupdating binaries done\e[0m\n"
echo
printf "\e[93;1mupdating integration ...\e[0m\n"
handleSystemd
handleLogrotate
printf "\e[93;1mupdating integration done\e[0m\n"
echo
printf "\e[93;1mupdating up container environment ...\e[0m\n"
updateContainerImages
handleContainerAssets
startContainers
printf "\e[93;1mupdating up container environment done\e[0m\n"
echo
printf "\e[92;1mupdate successful\e[0m\n"
echo