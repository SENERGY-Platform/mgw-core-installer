#!/bin/sh

setup_path=${0%/*}
if ! cd $setup_path
then
  exit 1
fi

. ./assets/scripts/lib.sh
. ./assets/scripts/os.sh
. ./assets/scripts/package.sh
. ./assets/scripts/github.sh
. ./assets/scripts/docker.sh

require_pkg="systemd: apt:"
install_pkg="curl: tar: gzip: jq: avahi-daemon:/usr/sbin/avahi-daemon openssl: gettext-base:envsubst logrotate:/usr/sbin/logrotate"
binaries="SENERGY-Platform/mgw-container-engine-wrapper SENERGY-Platform/mgw-host-manager"
systemd_path=/etc/systemd/system
logrotated_path=/etc/logrotate.d
mnt_path=/mnt/mgw
base_path=/opt/mgw
secrets_path=""
deployments_path=""
sockets_path=""
bin_path=""
container_path=""
log_path=""
no_root=false
bin_started=false
stack_name="mgw-core"
core_db_pw=""
core_db_root_pw=""
subnet_core="10.0.0.0"
subnet_module="10.1.0.0"
subnet_gateway="10.10.0.0"

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
    printf "missing required packages: %s\n" "$missing"
    exit 1
  fi
  missing=$(getMissingDockerPkg)
  if [ "$missing" != "" ]
  then
   printf "missing required packages: %s\n" "$missing"
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
  if ! mkdir -p $secrets_path $deployments_path $sockets_path $bin_path $container_path $log_path
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
  touch $bin_path/versions
  for repo in ${binaries}
  do
    echo "checking latest $repo release ..."
    if ! release="$(getGitHubRelease "$repo")"
    then
      exit 1
    fi
    if ! version="$(getGitHubReleaseVersion "$release")"
    then
      exit 1
    fi
    echo "downloading $repo $version ..."
    if ! asset_url="$(getGitHubReleaseAssetUrl "$release" "$platform")"
    then
      exit 1
    fi
    dl_pth="$wrk_spc/$repo"
    if ! mkdir -p $dl_pth
    then
      exit 1
    fi
    if ! file="$(downloadFile "$asset_url" "$dl_pth")"
    then
      exit 1
    fi
    echo "extracting $repo ..."
    if ! extract_path="$(extractTar "$file")"
    then
      exit 1
    fi
    echo "copying $repo ..."
    target_path="$bin_path/$repo"
    if ! mkdir -p $target_path
    then
      exit 1
    fi
    if ! cp -r $extract_path/$arch/* $target_path
    then
      exit 1
    fi
    echo "$repo:$version" >> $bin_path/versions
  done
  rm -r "$wrk_spc"
}

handleBinConfigs() {
  for repo in ${binaries}
  do
    if stat ./assets/bin/$repo > /dev/null 2>& 1
    then
      echo "copying $repo configs ..."
      files=$(ls ./assets/bin/$repo)
      for file in ${files}
      do
        if real_file="$(getTemplateBase "$file")"
        then
          if ! envsubst < ./assets/bin/$repo/$file > $bin_path/$repo/$real_file
          then
            exit 1
          fi
        else
          if ! cp ./assets/bin/$repo/$file $bin_path/$repo/$file
          then
            exit 1
          fi
        fi
      done
    fi
  done
}

copyUnits() {
  units=$2
  files=$(ls $1)
  if [ "$files" != "" ]
  then
    for file in ${files}
    do
      if real_file="$(getTemplateBase "$file")"
      then
        if ! envsubst < $1/$file > $systemd_path/$real_file
        then
          return 1
        fi
        file="$real_file"
      else
        if ! cp $1/$file $systemd_path/$file
        then
          return 1
        fi
      fi
      if [ "$units" = "" ]; then
        units="${units}$file"
      else
        units="${units} $file"
      fi
      echo "$file" >> $base_path/units
    done
  fi
  echo "$units"
}

handleSystemd() {
  touch $base_path/units
  units=""
  echo "copying systemd mount units ..."
  if ! units=$(copyUnits ./assets/units/mounts "$units")
  then
    exit 1
  fi
  echo "copying systemd service units ..."
  if ! units=$(copyUnits ./assets/units/services "$units")
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

saveSettings() {
  echo \
"base_path=$base_path
secrets_path=$secrets_path
deployments_path=$deployments_path
sockets_path=$sockets_path
bin_path=$bin_path
container_path=$container_path
log_path=$log_path
stack_name=$stack_name
subnet_core=$subnet_core
subnet_module=$subnet_module
subnet_gateway=$subnet_gateway
core_db_pw=$core_db_pw
core_db_root_pw=$core_db_root_pw
systemd_path=$systemd_path" \
  > $base_path/.settings
}

handleEnvExport() {
  export \
    BASE_PATH="$base_path" \
    SECRETS_PATH="$secrets_path" \
    DEPLOYMENTS_PATH="$deployments_path" \
    SOCKETS_PATH="$sockets_path" \
    BIN_PATH="$bin_path" \
    CONTAINER_PATH="$container_path" \
    LOG_PATH="$log_path" \
    STACK_NAME="$stack_name" \
    SUBNET_CORE="$subnet_core" \
    SUBNET_MODULE="$subnet_module" \
    SUBNET_GATEWAY="$subnet_gateway" \
    CORE_DB_PW="$core_db_pw" \
    CORE_DB_ROOT_PW="$core_db_root_pw"
}

handleIntegration() {
  if ! envsubst '$BIN_PATH' < ./assets/scripts/ctrl.sh.template > $base_path/ctrl.sh
  then
    exit 1
  fi
  if ! chmod +x $base_path/ctrl.sh
  then
    exit 1
  fi
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
      break
      ;;
    *)
      echo "unknown option"
    esac
  done
}

handleContainer() {
  echo "copying container configs ..."
  if ! cp -r ./assets/container/configs $container_path
  then
    exit 1
  fi
  echo "copying container environment file ..."
  if ! cp ./assets/container/.env $container_path/.env
  then
    exit 1
  fi
  echo "copying container compose file ..."
  if ! envsubst '$SECRETS_PATH $DEPLOYMENTS_PATH $SOCKETS_PATH $CONTAINER_PATH $STACK_NAME $SUBNET_CORE $SUBNET_MODULE $SUBNET_GATEWAY $CORE_DB_PW $CORE_DB_ROOT_PW' < ./assets/container/docker-compose.yml.template > $container_path/docker-compose.yml
  then
    exit 1
  fi
}

handleDocker() {
  echo "creating containers ..."
  cd $container_path
  if ! docker compose create
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
  cd $setup_path
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
    logrotated_path="$$LOGROTATED_PATH"
  fi
  if [ "$NO_ROOT" = "true" ]; then
      no_root=true
  fi
}

checkRoot() {
  if [ "$no_root" = false ]
  then
    if ! isRoot
    then
      echo "root privileges required"
      exit 1
    fi
  fi
}

handleOptions
checkRoot
while :
do
  printf "\e[96;1minstall multi-gateway core? (y/n):\e[0m "
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
printf "\e[95;1msetting up installer ...\e[0m\n"
handleDefaultSettings
handleDatabasePasswords
handleEnvExport
printf "\e[95;1msetting up installer done\e[0m\n"
echo
printf "\e[95;1msetting up required packages ...\e[0m\n"
handlePackages
printf "\e[95;1msetting up required packages done\e[0m\n"
echo
printf "\e[95;1msetting up install directory ...\e[0m\n"
prepareInstallDir
saveSettings
printf "\e[95;1msetting up install done\e[0m\n"
echo
printf "\e[95;1msetting up binaries ...\e[0m\n"
handleBin
handleBinConfigs
printf "\e[95;1msetting up binaries done\e[0m\n"
echo
printf "\e[95;1msetting up integration ...\e[0m\n"
handleIntegration
printf "\e[95;1msetting up integration done\e[0m\n"
echo
printf "\e[95;1msetting up container environment ...\e[0m\n"
handleContainer
handleDocker
printf "\e[95;1msetting up container environment done\e[0m\n"
echo
printf "\e[92;1minstallation successful\e[0m\n"
echo