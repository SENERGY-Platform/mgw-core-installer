#!/bin/sh

. ./assets/scripts/lib.sh
. ./assets/scripts/os.sh
. ./assets/scripts/package.sh
. ./assets/scripts/github.sh
. ./assets/scripts/docker.sh

require_pkg="systemd: apt:"
install_pkg="curl: tar: gzip: jq: avahi-daemon: openssl: gettext-base:envsubst"
binaries="SENERGY-Platform/mgw-container-engine-wrapper SENERGY-Platform/mgw-host-manager"
systemd_units_path=/etc/systemd/system
mnt_path=/mnt/mgw
base_path=/opt/mgw
stack_name=mgw-core
core_db_pw=
core_db_root_pw=
subnet_core=10.0.0.0
subnet_module=10.1.0.0
subnet_gateway=10.10.0.0

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
  mkdir -p $base_path/deployments $mnt_path/secrets $base_path/sockets $base_path/bin
}

handleBin() {
  wrk_spc="/tmp/mgw-install"
  mkdir -p $wrk_spc
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
    mkdir -p $dl_pth
    if ! file="$(downloadFile "$asset_url" "$dl_pth")"
    then
      exit 1
    fi
    echo "extracting $file ..."
    if ! extract_path="$(extractTar "$file")"
    then
      exit 1
    fi
    target_path="$base_path/bin/$repo"
    mkdir -p $target_path
    if ! cp -r $extract_path/$arch/* $target_path
    then
      exit 1
    fi
    echo "$repo $version" >> $base_path/bin/versions
  done
  rm -r "$wrk_spc"
}

handleBinConfigs() {
  export BASE_PATH="$base_path"
  for repo in ${binaries}
  do
    if stat ./assets/bin/$repo > /dev/null 2>& 1
    then
      echo "adding $repo configs ..."
      files=$(ls ./assets/bin/$repo)
      for file in ${files}
      do
        if real_file="$(getTemplateBase "$file")"
        then
          if ! envsubst < ./assets/bin/$repo/$file > $base_path/bin/$repo/$real_file
          then
            exit 1
          fi
        else
          if ! cp ./assets/bin/$repo/$file $base_path/bin/$repo/$file
          then
            exit 1
          fi
        fi
      done
    fi
  done
}

handleDefaultSettings() {
  printf "change default settings? (y/n): "
  while :
  do
    read -r choice
    case "$choice" in
      y)
        printf "install directory [%s]: " "$base_path"
        read -r input
        if [ "$input" != "" ]; then
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
}

handleDatabasePasswords() {
  if [ "$core_db_pw" = "" ]
  then
    if ! core_db_pw="$(openssl rand -hex 16)"
    then
      exit 1
    fi
    printf "generated core database password: %s\n" "$core_db_pw"
  fi
  if [ "$core_db_root_pw" = "" ]
  then
    if ! core_db_root_pw="$(openssl rand -hex 16)"
    then
      exit 1
    fi
    printf "generated core database root password: %s\n" "$core_db_root_pw"
  fi
}

if ! isRoot
then
  echo "root privileges required"
  exit 1
fi
handleDefaultSettings
handleDatabasePasswords
handlePackages
prepareInstallDir
handleBin
handleBinConfigs
