#!/bin/sh

. ./assets/scripts/lib.sh
. ./assets/scripts/os.sh
. ./assets/scripts/package.sh
. ./assets/scripts/github.sh
. ./assets/scripts/docker.sh

require_pkg="systemd: apt:"
install_pkg="curl: tar: gzip: jq: avahi-daemon: openssl: gettext-base:envsubst"
binaries="SENERGY-Platform/mgw-container-engine-wrapper SENERGY-Platform/mgw-host-manager"
systemd_path=/etc/systemd/system
mnt_path=/mnt/mgw
base_path=/opt/mgw
secrets_path=""
deployments_path=""
sockets_path=""
bin_path=""
container_path=""
units_path=""
no_root=false
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
    printf "the following new packages will be installed: %s \n" "$missing"
    while :
    do
      printf "continue? (y/n): "
      read -r choice
      case "$choice" in
      y)
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
  if ! mkdir -p $secrets_path $deployments_path $sockets_path $bin_path $container_path $units_path
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
    echo "$repo $version" >> $bin_path/versions
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

handleUnits() {
  while :
  do
    printf "include systemd services? (y/n): "
    read -r choice
    case "$choice" in
    y)
      echo "copying systemd services ..."
      files=$(ls ./assets/units/services)
      for file in ${files}
      do
        if real_file="$(getTemplateBase "$file")"
        then
          if ! envsubst < ./assets/units/services/$file > $units_path/$real_file
          then
            exit 1
          fi
          file="$real_file"
        else
          if ! cp ./assets/units/services/$file $units_path/$file
          then
            exit 1
          fi
        fi
      done
      break
      ;;
    n)
      break
      ;;
    *)
      echo "unknown option"
    esac
  done
  echo "copying systemd mounts ..."
  files=$(ls ./assets/units/mounts)
  for file in ${files}
  do
    if real_file="$(getTemplateBase "$file")"
    then
      if ! envsubst < ./assets/units/mounts/$file > $units_path/$real_file
      then
        exit 1
      fi
      file="$real_file"
    else
      if ! cp ./assets/units/mounts/$file $units_path/$file
      then
        exit 1
      fi
    fi
  done
}

handleSystemd() {
  units=$(ls $units_path)
  if [ "$units" != "" ]
  then
    if ! cp $units_path/* $systemd_path
    then
      exit 1
    fi
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
  fi
}

handleDefaultSettings() {
  while :
  do
    printf "change default settings? (y/n): "
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
      n)
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
  units_path=$base_path/units
  export \
    SECRETS_PATH="$secrets_path" \
    DEPLOYMENTS_PATH="$deployments_path" \
    SOCKETS_PATH="$sockets_path" \
    BIN_PATH="$bin_path" \
    CONTAINER_PATH="$container_path" \
    STACK_NAME="$stack_name" \
    SUBNET_CORE="$subnet_core" \
    SUBNET_MODULE="$subnet_module" \
    SUBNET_GATEWAY="$subnet_gateway"
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
  export CORE_DB_PW="$core_db_pw" CORE_DB_ROOT_PW="$core_db_root_pw"
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
  printf "install multi-gateway core? (y/n): "
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
echo
echo "setting-up installer ..."
handleDefaultSettings
handleDatabasePasswords
echo "setting-up installer done"
echo
echo "setting-up required packages ..."
handlePackages
echo "setting-up required packages done"
echo
echo "setting-up install directory ..."
prepareInstallDir
echo "setting-up install done"
echo
echo "setting-up binaries ..."
handleBin
handleBinConfigs
echo "setting-up binaries done"
echo
echo "setting-up systemd integration ..."
handleUnits
#handleSystemd
echo "setting-up systemd integration done"
echo
echo "setting-up containers ..."
handleContainer
echo "setting-up containers done"