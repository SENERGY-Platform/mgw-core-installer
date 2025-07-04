#!/bin/sh


if ! cd ${0%/*}
then
  exit 1
fi

. ./assets/scripts/lib/settings.sh

read_config=false
while getopts ':c:h' opt; do
  case "$opt" in
    c)
      echo "Reading config from '${OPTARG}'"
      . ${OPTARG}
      read_config=true
      ;;

    h)
      echo "Usage: $(basename $0) [-c configfile]\n If a config file is given, the installer will run non-interactive mode."
      exit 0
      ;;

    ?)
      echo "Invalid command option.\nUsage: $(basename $0) [-c configfile]"
      exit 1
      ;;
  esac
done
shift "$(($OPTIND -1))"

. ./assets/.options
. ./assets/scripts/lib/util.sh
. ./assets/scripts/lib/os.sh
. ./assets/scripts/lib/package.sh
. ./assets/scripts/lib/github.sh
. ./assets/scripts/lib/docker.sh
. ./assets/scripts/lib/container.sh
. ./assets/scripts/lib/sem_ver.sh

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
    printColor "the following new packages will be installed: " "$blue" "nb"
    echo "$missing"
    while :
    do
      if [ "$skip_pgk_install_confirm" != "true" ]
      then
        printColor "continue? (y/n): " "$blue" "nb"
        read -r choice
      else
        choice=y
      fi
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
  if ! mkdir -p $secrets_path $deployments_path $sockets_path $bin_path $container_path $log_path $scripts_path $mounts_path $mounts_path/nginx $mounts_path/kratos
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
  if ! cp .version $base_path/.version
  then
    exit 1
  fi
}

handleBin() {
  wrk_spc="/tmp/mgw-install"
  rm -r $wrk_spc > /dev/null 2>& 1
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
  if [ "$systemd" = "true" ]
  then
    units=""
    echo "copying systemd mount units ..."
    if ! units=$(copyWithTemplates ./assets/units/mounts $systemd_path "$units" "mnt-$core_name-")
    then
      exit 1
    fi
    echo "copying systemd service units ..."
    if ! units=$(copyWithTemplates ./assets/units/services $systemd_path "$units" "$core_name-")
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
  fi
}

handleLogrotate() {
  if [ "$logrotate" = "true" ]
  then
    echo "copying logrotate config ..."
    if ! envsubst < ./assets/logrotate/mgw_core.template > $logrotated_path/"$core_name"_core
    then
      exit 1
    fi
  fi
}

handleCron() {
  if [ "$cron" = "true" ]
  then
    echo "creating cronjob ..."
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
    echo "creating avahi service ..."
    if ! envsubst < ./assets/avahi/core.service.template > $avahi_path/"$core_name"_core.service
    then
      exit 1
    fi
  fi
}

handleDefaultSettings() {
  while :
  do
    if [ "$read_config" = "true" ]
    then
      choice=n
    else
      printColor "change default settings? (y/n): " "$blue" "nb"
      read -r choice
    fi
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
        printf "core id [%s]: " "$core_id"
        read -r input
        if [ "$input" != "" ]; then
          core_id="$input"
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
        printf "gateway port [%s]: " "$gateway_port"
        read -r input
        if [ "$input" != "" ]; then
          gateway_port="$input"
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
  deployments_path=$base_path/deployments
  sockets_path=$base_path/sockets
  bin_path=$base_path/bin
  container_path=$base_path/container
  log_path=$base_path/log
  scripts_path=$base_path/scripts
  mounts_path=$base_path/mounts
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

handleCoreUserPassword() {
  if [ "$core_usr_pw" = "" ]
  then
    if ! core_usr_pw="$(openssl rand -hex 16)"
    then
      exit 1
    fi
  fi
}

handleCoreID() {
  if [ "$core_id" = "" ]
  then
    if ! core_id="$(openssl rand -hex 4)"
    then
      exit 1
    fi
  fi
}

handleCoreName() {
  if [ "$core_name" = "" ]
  then
    core_name="mgw_$core_id"
  fi
}

handleSecretsPath() {
  secrets_path=/mnt/$core_name/secrets
}

handleStackName() {
  if [ "$stack_name" = "" ]
  then
    stack_name="$core_name"
  fi
}

handleBetaRelease() {
  if [ "$read_config" != "true" ]
  then
    while :
    do
      printColor "allow beta releases? (y/n): " "$blue" "nb"
      read -r choice
      case "$choice" in
      y)
        allow_beta=true
        break
        ;;
      n)
        allow_beta=false
        break
        ;;
      *)
        echo "unknown option"
      esac
    done
  fi
}

handleIntegration() {
  if [ "$read_config" != "true" ]
  then
    while :
    do
      printColor "enable OS startup integration? (y/n): " "$blue" "nb"
      read -r choice
      case "$choice" in
      y)
        systemd=true
        break
        ;;
      n)
        systemd=false
        echo "please use 'ctrl.sh' for manual control"
        break
        ;;
      *)
        echo "unknown option"
      esac
    done
    while :
    do
      printColor "enable log rotation? (y/n): " "$blue" "nb"
      read -r choice
      case "$choice" in
      y)
        logrotate=true
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
    while :
    do
      printColor "enable automatic updates? (y/n): " "$blue" "nb"
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
}

handleDocker() {
  echo "creating containers ..."
  if ! cd $container_path
  then
    exit
  fi
  if ! dockerCompose up --no-start
  then
    exit 1
  fi
  if [ "$bin_started" = "true" ]
  then
    while :
    do
      if [ "$read_config" = "true" ]
      then
        if [ "$start_containers" = "true" ]
        then
          choice=y
        else
          choice=n
        fi
      else
        printColor "start containers? (y/n): " "$blue" "nb"
        read -r choice
      fi
      case $choice in
      y)
        if ! dockerCompose start
        then
          exit 1
        fi
        break
        ;;
      n)
        echo "please use 'ctrl.sh' for manual control or reboot your system"
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
  if [ "$SYSTEMD_PATH" != "" ]
  then
    case $SYSTEMD_PATH in
      /*)
        ;;
      *)
        echo "systemd path must be absolute"
        exit 1
    esac
    systemd_path="$SYSTEMD_PATH"
  fi
  if [ "$LOGROTATED_PATH" != "" ]
  then
    case $LOGROTATED_PATH in
      /*)
        ;;
      *)
        echo "logrotate.d path must be absolute"
        exit 1
    esac
    logrotated_path="$LOGROTATED_PATH"
  fi
  if [ "$CRON_PATH" != "" ]
  then
    case $CRON_PATH in
      /*)
        ;;
      *)
        echo "cron path must be absolute"
        exit 1
    esac
    cron_path="$CRON_PATH"
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
if [ "$read_config" != "true" ]
then
  while :
  do
    printColor "install multi-gateway core $version? (y/n): " "$blue" "nb"
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
fi
printLnBr
printColor "setting up installer ..." "$yellow"
detectDockerCompose
handleDefaultSettings
handleCoreID
handleCoreName
handleSecretsPath
handleStackName
handleDatabasePasswords
handleCoreUserPassword
handleIntegration
handleBetaRelease
parseImages
exportSettingsToEnv
printColor "setting up installer done" "$yellow"
printLnBr
printColor "setting up required packages ..." "$yellow"
handlePackages
printColor "setting up required packages done" "$yellow"
printLnBr
printColor "setting up install directory ..." "$yellow"
prepareInstallDir
printColor "setting up install directory done" "$yellow"
printLnBr
printColor "setting up binaries ..." "$yellow"
handleBin
handleBinConfigs
printColor "setting up binaries done" "$yellow"
printLnBr
printColor "setting up integration ..." "$yellow"
handleSystemd
handleLogrotate
handleCron
handleAvahi
printColor "setting up integration done" "$yellow"
printLnBr
printColor "setting up container environment ..." "$yellow"
copyContainerAssets
handleGatewayUserFile
handleDocker
printColor "setting up container environment done" "$yellow"
saveSettings
printLnBr
printColor "installation successful" "$yellow"
printLnBr