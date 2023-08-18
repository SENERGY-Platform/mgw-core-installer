#!/bin/sh

script_path=${0%/*}
if ! cd $script_path
then
  exit 1
fi

repo="SENERGY-Platform/mgw-core-installer"
install_path=$1
wrk_spc="/tmp/mgw-update"
units=""

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

handleSystemdPre() {
  installed=""
  if stat $base_path/.units > /dev/null 2>& 1
  then
    installed="$(readFileToArray $base_path/.units)"
    for unit in ${installed}
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
  fi
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
  if [ "$installed" != "" ]
  then
    for unit in ${installed}
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
}

handleSystemdPost() {
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
}

handleLogrotate() {
  echo "updating logrotate config ..."
  if ! envsubst < ./assets/logrotate/mgw_core.template > $logrotated_path/mgw_core
  then
    exit 1
  fi
}

handleDockerPre() {
  cd $container_path
  echo "updating container images ..."
  if ! docker compose pull
  then
    exit 1
  fi
  echo "stopping containers ..."
  if ! docker compose stop
  then
    exit 1
  fi
}

handleDockerPost() {
  echo "starting containers ..."
  if ! docker compose up -d
  then
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

. ./assets/scripts/lib/var
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
#saveSettings
printf "\e[93;1msetting up updater done\e[0m\n"
echo
printf "\e[93;1msetting up required packages ...\e[0m\n"
handlePackages
printf "\e[93;1msetting up required packages done\e[0m\n"
