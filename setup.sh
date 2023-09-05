#!/bin/sh


if ! cd ${0%/*}
then
  exit 1
fi

. ./assets/.options
. ./assets/scripts/lib/settings.sh
. ./assets/scripts/lib/util.sh
. ./assets/scripts/lib/os.sh
. ./assets/scripts/lib/package.sh
. ./assets/scripts/lib/github.sh
. ./assets/scripts/lib/docker.sh
. ./assets/scripts/lib/container.sh

setup_path=$(pwd)
version="$(cat .version)"
bin_started=false

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
  missing=$(getMissingPkg "$require_pkg")
  if [ "$missing" != "" ]
  then
    echo "missing required packages: $missing"
    exit 1
  fi
  missing=$(getMissingDockerPkg)
  if [ "$missing" != "" ]
  then
   echo "missing required packages: $missing"
   echo "please follow instructions at 'https://docs.docker.com/engine/install' and run setup again"
   exit 1
  fi
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

prepareInstallDir() {
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

handleBin() {
  wrk_spc="/tmp/mgw-install"
  if ! mkdir -p $wrk_spc
  then
    exit 1
  fi
  for item in ${binaries}
  do
    repo="${item%%:*}"
    version="${item##*:}"
    echo "getting $repo release $version ..."
    if ! release="$(getGitHubRelease "$repo" "$version")"
    then
      rm -r $wrk_spc
      exit 1
    fi
    if ! asset_url="$(getGitHubReleaseAssetUrl "$release" "$platform")"
    then
      rm -r $wrk_spc
      exit 1
    fi
    dl_pth="$wrk_spc/$repo"
    if ! mkdir -p $dl_pth
    then
      rm -r $wrk_spc
      exit 1
    fi
    echo "downloading ..."
    if ! file="$(downloadFile "$asset_url" "$dl_pth")"
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
    echo "copying ..."
    target_path="$bin_path/$repo"
    if ! mkdir -p $target_path
    then
      rm -r $wrk_spc
      exit 1
    fi
    if ! cp -r $extract_path/$arch/* $target_path
    then
      rm -r $wrk_spc
      exit 1
    fi
    echo "$item" >> $base_path/.binaries
  done
  rm -r $wrk_spc
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

handleSystemd() {
  units=""
  echo "copying systemd mount units ..."
  if ! units=$(copyWithTemplates ./assets/units/mounts $systemd_path "$units")
  then
    exit 1
  fi
  echo "copying systemd service units ..."
  if ! units=$(copyWithTemplates ./assets/units/services $systemd_path "$units")
  then
    exit 1
  fi
  if [ "$units" != "" ]
  then
    echo "reloading systemd ..."
    if ! systemctl daemon-reload
    then
      exit 1
    fi
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
    bin_started=true
  fi
}

handleLogrotate() {
  echo "copying logrotate config ..."
  if ! envsubst < ./assets/logrotate/mgw_core.template > $logrotated_path/mgw_core
  then
    exit 1
  fi
}

handleDefaultSettings() {
  while :
  do
    printf "\e[96;1mchange default settings? (n/y):\e[0m "
    read -r choice
    case "$choice" in
      y)
        printf "install directory [%s]: " "$base_path"
        read -r input
        if [ "$input" != "" ]; then
          case $input in
            /*)
              ;;
            *)
              echo "must be absolute path"
              exit 1
          esac
          base_path="$input"
        fi
        printf "stack name [%s]: " "$stack_name"
        read -r input
        if [ "$input" != "" ]; then
          stack_name="$input"
        fi
        printf "core database password [%s]: " "$core_db_pw"
        read -r input
        if [ "$input" != "" ]; then
          core_db_pw="$input"
        fi
        printf "core database root password [%s]: " "$core_db_root_pw"
        read -r input
        if [ "$input" != "" ]; then
          core_db_root_pw="$input"
        fi
        printf "core subnet [%s]: " "$subnet_core"
        read -r input
        if [ "$input" != "" ]; then
          subnet_core="$input"
        fi
        printf "module subnet [%s]: " "$subnet_module"
        read -r input
        if [ "$input" != "" ]; then
          subnet_module="$input"
        fi
        printf "gateway subnet [%s]: " "$subnet_gateway"
        read -r input
        if [ "$input" != "" ]; then
          subnet_gateway="$input"
        fi
        break
        ;;
      n|"")
        break
        ;;
      *)
        echo "unknown option"
    esac
  done
  secrets_path=$mnt_path/secrets
  deployments_path=$base_path/deployments
  sockets_path=$base_path/sockets
  bin_path=$base_path/bin
  container_path=$base_path/container
  log_path=$base_path/log
  scripts_path=$base_path/scripts
}

handleDatabasePasswords() {
  if [ "$core_db_pw" = "" ]
  then
    if ! core_db_pw="$(openssl rand -hex 16)"
    then
      exit 1
    fi
  fi
  if [ "$core_db_root_pw" = "" ]
  then
    if ! core_db_root_pw="$(openssl rand -hex 16)"
    then
      exit 1
    fi
  fi
}

handleIntegration() {
  while :
  do
    printf "\e[96;1muse systemd? (y/n):\e[0m "
    read -r choice
    case "$choice" in
    y|"")
      handleSystemd
      break
      ;;
    n)
      systemd=false
      echo "please use 'ctrl.sh (start/stop)' for manual control"
      break
      ;;
    *)
      echo "unknown option"
    esac
  done
  while :
  do
    printf "\e[96;1muse logrotate? (y/n):\e[0m "
    read -r choice
    case "$choice" in
    y|"")
      handleLogrotate
      break
      ;;
    n)
      logrotate=false
      break
      ;;
    *)
      echo "unknown option"
    esac
  done
}

handleDocker() {
  echo "creating containers ..."
  if ! cd $container_path
  then
    exit
  fi
  if ! docker compose up --no-start
  then
    exit 1
  fi
  if [ "$bin_started" = "true" ]
  then
    while :
    do
      printf "\e[96;1mstart containers? (y/n):\e[0m "
      read -r choice
      case $choice in
      y|"")
        if ! docker compose start
        then
          exit 1
        fi
        break
        ;;
      n)
        echo "please use 'docker compose start' to manually start containers"
        break
        ;;
      *)
        echo "unknown option"
      esac
    done
  fi
  if ! cd $setup_path
  then
    exit 1
  fi
}

handleOptions() {
  if [ "$SYSTEMD_PATH" != "" ]; then
    case $SYSTEMD_PATH in
      /*)
        ;;
      *)
        echo "systemd path must be absolute"
        exit 1
    esac
    systemd_path="$SYSTEMD_PATH"
  fi
  if [ "$LOGROTATED_PATH" != "" ]; then
    case $LOGROTATED_PATH in
      /*)
        ;;
      *)
        echo "logrotate.d path must be absolute"
        exit 1
    esac
    logrotated_path="$LOGROTATED_PATH"
  fi
}

checkRoot() {
  if ! isRoot
  then
    echo "root privileges required"
    exit 1
  fi
}

handleOptions
checkRoot
while :
do
  printf "\e[96;1minstall multi-gateway core %s? (y/n):\e[0m " "$version"
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
printf "\e[93;1msetting up installer ...\e[0m\n"
handleDefaultSettings
handleDatabasePasswords
exportSettingsToEnv
printf "\e[93;1msetting up installer done\e[0m\n"
echo
printf "\e[93;1msetting up required packages ...\e[0m\n"
handlePackages
printf "\e[93;1msetting up required packages done\e[0m\n"
echo
printf "\e[93;1msetting up install directory ...\e[0m\n"
prepareInstallDir
printf "\e[93;1msetting up install directory done\e[0m\n"
echo
printf "\e[93;1msetting up binaries ...\e[0m\n"
handleBin
handleBinConfigs
printf "\e[93;1msetting up binaries done\e[0m\n"
echo
printf "\e[93;1msetting up integration ...\e[0m\n"
handleIntegration
printf "\e[93;1msetting up integration done\e[0m\n"
echo
printf "\e[93;1msetting up container environment ...\e[0m\n"
copyContainerAssets
handleDocker
printf "\e[93;1msetting up container environment done\e[0m\n"
echo
saveSettings
printf "\e[92;1minstallation successful\e[0m\n"
echo