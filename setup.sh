#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# Installs a fresh multi-gateway core (PLAN.md 10a). Lives in the root of the release archive (or a
# git clone), next to assets/, and is not installed.
#
#   sudo ./setup.sh             interactive
#   sudo ./setup.sh -c <file>   non-interactive, everything from the config file
#                               (assets/setup.conf.example is the template)
#
# The install leaves the core in exactly the state an update would leave behind, built with the same
# building blocks. From the moment the core root exists, every object is recorded in state/install
# before it is created; a failure removes everything again, and a killed install is cleaned up by
# the next setup.sh, the recovery unit or ctrl.sh.

# the libraries' variables (host_*, state_*, setup_*, objects_record) and the package lists of options
# are used across files, which shellcheck can't follow
# shellcheck disable=SC2034,SC2154

if ! cd "${0%/*}"
then
  exit 1
fi

lib=./assets/scripts/lib
for setup_lib in file settings state lock log host render reconcile net docker objects core version setup
do
  # shellcheck disable=SC1090
  . "$lib/$setup_lib.sh" || exit 1
done

usage() {
  echo "usage: $0 [-c <config file>]"
  echo "  without -c, the installer asks; with -c, it takes everything from the config file"
}

config_file=""
while getopts ':c:h' opt
do
  case "$opt" in
    c)
      config_file="$OPTARG"
      ;;
    h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
  esac
done

auto=false
if [ "$config_file" != "" ]
then
  auto=true
fi

if [ -f ./assets/version ]
then
  version="$(cat ./assets/version)"
else
  # a git clone has no assets/version, the release build writes it
  version="dev-$(date +%s)"
fi

say() {
  printf '%s\n' "$*"
}

fail() {
  say "$*" >&2
  exit 1
}

# asks $1 with the default $2 in brackets until setupValidate accepts the answer for the key $3;
# prints the answer
ask() {
  while :
  do
    printf '%s [%s]: ' "$1" "$2" >&2
    read -r ask_answer || exit 1
    ask_answer="${ask_answer:-$2}"
    if [ "$3" = "" ] || setupValidate "$3" "$ask_answer"
    then
      printf '%s\n' "$ask_answer"
      return
    fi
  done
}

# asks the yes/no question $1; returns 0 for yes. Enter takes the default: yes, or no if $2 is "n"
askYes() {
  ask_default=y
  ask_hint="Y/n"
  if [ "$2" = "n" ]
  then
    ask_default=n
    ask_hint="y/N"
  fi
  while :
  do
    printf '%s (%s): ' "$1" "$ask_hint" >&2
    read -r ask_answer || exit 1
    case "${ask_answer:-$ask_default}" in
      y|Y)
        return 0
        ;;
      n|N)
        return 1
        ;;
      *)
        say "please answer y or n" >&2
    esac
  done
}

# asks the yes/no question $1 (default as askYes, $2); prints true or false
askBool() {
  if askYes "$1" "$2"
  then
    echo true
  else
    echo false
  fi
}

# prints $1 random bytes as hex
randomHex() {
  od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

# --- 1. checks, nothing changed yet ---

if [ "$(id -u)" != "0" ]
then
  fail "root privileges required"
fi
hostPlatform > /dev/null || exit 1
hostArch > /dev/null || exit 1
if ! command -v docker > /dev/null 2>&1 || ! docker compose version > /dev/null 2>&1
then
  fail "docker with the compose plugin is required, see https://docs.docker.com/engine/install"
fi
if ! version_folder="$(versionFolder "$version")"
then
  exit 1
fi
if ! settingsLoad ./assets/settings.defaults ""
then
  exit 1
fi
# the version's own static asset: the package lists, binaries and images
# shellcheck disable=SC1091
. ./assets/options || exit 1

# --- 3. the questions, or the config file ---

if [ "$auto" = "true" ]
then
  say "reading config file '$config_file' ..."
  configLoad "$config_file" || exit 1
else
  if ! askYes "install multi-gateway core $version?"
  then
    exit 0
  fi
  if askYes "change default settings?" n
  then
    setupSet install_dir "$(ask "install directory" /opt/mgw install_dir)"
    setupSet core_id "$(ask "core id (empty: generated)" "" "")"
    while [ "$(setupGet core_id)" != "" ] && ! setupValidate core_id "$(setupGet core_id)"
    do
      setupSet core_id "$(ask "core id (empty: generated)" "" "")"
    done
    setupSet core_usr "$(ask "core user" "$(setupGet core_usr)" core_usr)"
    for setup_pw in core_db_pw core_db_root_pw
    do
      setup_pw_answer="$(ask "$setup_pw (empty: generated)" "" "")"
      while [ "$setup_pw_answer" != "" ] && ! setupValidate "$setup_pw" "$setup_pw_answer"
      do
        setup_pw_answer="$(ask "$setup_pw (empty: generated)" "" "")"
      done
      setupSet "$setup_pw" "$setup_pw_answer"
    done
    setupSet gateway_port "$(ask "gateway port" "$(setupGet gateway_port)" gateway_port)"
    setupSet subnet_core "$(ask "core subnet (/28)" "$(setupGet subnet_core)" subnet_core)"
    setupSet subnet_module "$(ask "module subnet (/16)" "$(setupGet subnet_module)" subnet_module)"
    setupSet subnet_gateway "$(ask "gateway subnet (/28)" "$(setupGet subnet_gateway)" subnet_gateway)"
    setup_hd="$(ask "host dir repository path (empty: <core root>/repositories/host_dir)" "" "")"
    while [ "$setup_hd" != "" ] && ! setupValidate host_dir_repository_path "$setup_hd"
    do
      setup_hd="$(ask "host dir repository path (empty: <core root>/repositories/host_dir)" "" "")"
    done
    setupSet host_dir_repository_path "$setup_hd"
  fi
  setupSet autostart "$(askBool "start the core at boot (systemd)?")"
  setupSet logrotate "$(askBool "enable log rotation?")"
  setupSet cron "$(askBool "enable automatic updates?")"
  setupSet advertise "$(askBool "enable mDNS advertisement?")"
  setupSet allow_beta "$(askBool "allow beta releases?" n)"
  setupSet start_core "$(askBool "start the core after the installation?")"
fi

# --- 6. the generated and derived settings (od instead of openssl: no package needed yet) ---

install_dir="$(setupGet install_dir)"
install_dir="${install_dir:-/opt/mgw}"
setupSet install_dir "$install_dir"
[ "$(setupGet core_id)" != "" ] || setupSet core_id "$(randomHex 4)"
[ "$(setupGet core_name)" != "" ] || setupSet core_name "mgw_$(setupGet core_id)"
[ "$(setupGet stack_name)" != "" ] || setupSet stack_name "$(setupGet core_name)"
for setup_pw in core_usr_pw core_db_pw core_db_root_pw
do
  [ "$(setupGet "$setup_pw")" != "" ] || setupSet "$setup_pw" "$(randomHex 16)"
done
core_root="$install_dir/$(setupGet core_id)"
[ "$(setupGet host_dir_repository_path)" != "" ] || setupSet host_dir_repository_path "$core_root/repositories/host_dir"
if ! setupValidateAll
then
  exit 1
fi
core_name="$(setupGet core_name)"
stack_name="$(setupGet stack_name)"

# --- 1. checks of the install directory ---

setup_dir="$install_dir"
while ! [ -e "$setup_dir" ]
do
  setup_dir="${setup_dir%/*}"
  setup_dir="${setup_dir:-/}"
done
if [ "$(findmnt -n -o TARGET --target "$setup_dir")" != "/" ]
then
  fail "'$install_dir' isn't on the root file system: systemd needs the unit files it links there at boot"
fi
if [ -e "$install_dir/.settings" ]
then
  fail "'$install_dir' contains an installation of an older installer; its update.sh migrates it"
fi

# --- 2. unfinished installs ---

if [ -d "$install_dir" ]
then
  for setup_unfinished in $(setupUnfinished "$install_dir")
  do
    say "unfinished install found: $setup_unfinished"
    if [ "$auto" = "false" ] && ! askYes "remove it?"
    then
      fail "not installing next to an unfinished install"
    fi
    (
      lockAcquire "$setup_unfinished/state/lock" setup.sh || exit 1
      installCleanup "$setup_unfinished" "$setup_unfinished/state/install"
    ) || fail "removing the unfinished install '$setup_unfinished' failed, see its state/install"
  done
fi

# --- 4. collision checks, nothing changed yet ---

setup_collisions=""
collision() {
  setup_collisions="${setup_collisions}  $*$state_nl"
}
[ ! -e "$core_root" ] || collision "$core_root exists"
for setup_f in "$host_systemd_path/$core_name"-* "$host_systemd_path/$(systemd-escape --path --suffix=mount "/mnt/$core_name/secrets" 2> /dev/null)" \
  "$host_logrotated_path/$core_name"_* "$host_cron_path/$core_name"_* "$host_avahi_path/$core_name"_*
do
  if [ -e "$setup_f" ] || [ -L "$setup_f" ]
  then
    collision "$setup_f exists"
  fi
done
for setup_v in $(docker volume ls -q | grep "^${stack_name}_")
do
  collision "docker volume $setup_v exists"
done
for setup_n in $(docker network ls --format '{{.Name}}' | grep "^$core_name-.*-net\$")
do
  collision "docker network $setup_n exists"
done
setup_port="$(setupGet gateway_port)"
if setupPortInUse "$setup_port"
then
  collision "port $setup_port is in use"
fi
# shellcheck disable=SC2046 # one argument per network id
for setup_subnet in $(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' $(docker network ls -q) 2> /dev/null)
do
  case "$setup_subnet" in
    *:*)
      continue
  esac
  for setup_ours in "$(setupGet subnet_core)/28" "$(setupGet subnet_gateway)/28" "$(setupGet subnet_module)/16"
  do
    if subnetsOverlap "$setup_ours" "$setup_subnet"
    then
      collision "subnet $setup_ours overlaps $setup_subnet of an existing docker network"
    fi
  done
done
if [ "$setup_collisions" != "" ]
then
  say "not installing, the core would collide with:" >&2
  printf '%s' "$setup_collisions" >&2
  fail "leftovers of a core with this name can be repaired with restore.sh; otherwise choose another core id, port or subnets"
fi

# --- 5. packages ---

setup_required="$require_pkg"
[ "$(setupGet autostart)" = "true" ] && setup_required="$setup_required $require_pkg_systemd"
setup_missing="$(setupMissingPkg "$setup_required")"
if [ "$setup_missing" != "" ]
then
  fail "missing required packages: $setup_missing"
fi
setup_install="$install_pkg"
[ "$(setupGet logrotate)" = "true" ] && setup_install="$setup_install $install_pkg_logrotate"
[ "$(setupGet cron)" = "true" ] && setup_install="$setup_install $install_pkg_cron"
[ "$(setupGet advertise)" = "true" ] && setup_install="$setup_install $install_pkg_advertise"
setup_missing="$(setupMissingPkg "$setup_install")"
if [ "$setup_missing" != "" ]
then
  say "the following packages will be installed: $setup_missing"
  if [ "$auto" = "false" ] && [ "$(setupGet skip_pkg_install_confirm)" != "true" ] && ! askYes "continue?"
  then
    exit 0
  fi
  # shellcheck disable=SC2086 # one argument per package
  if ! apt-get update || ! apt-get install -y $setup_missing
  then
    fail "installing packages failed"
  fi
fi

# --- 7. core root, record, lock ---

record="$core_root/state/install"

# removes everything recorded so far and ends the install
setupAbort() {
  trap - INT TERM HUP
  say "$1, removing what the install created ..." >&2
  if ! installCleanup "$core_root" "$record"
  then
    say "the cleanup left something behind, listed in $record; the next setup.sh tries again" >&2
  fi
  lockRelease 2> /dev/null
  exit 1
}

if ! mkdir -p "$install_dir" || ! mkdir "$core_root" || ! mkdir "$core_root/state"
then
  fail "cannot create '$core_root'"
fi
installRecordBegin "$record" "$version_folder" install || { rm -rf "$core_root"; fail "cannot write '$record'"; }
installRecordAdd "$record" folder:. || { rm -rf "$core_root"; fail "cannot write '$record'"; }
trap 'setupAbort "interrupted"' INT TERM HUP
if ! lockAcquire "$core_root/state/lock" install
then
  setupAbort "cannot take the lock"
fi
objects_record="$record"

# --- 8. state/settings ---

say "writing state/settings ..."
for setup_key in ${setup_pinned} ${setup_set}
do
  if ! settingsKnown "$setup_key"
  then
    continue
  fi
  settingsSet "$core_root/state/settings" "$setup_key" "$(setupGet "$setup_key")" || setupAbort "cannot write state/settings"
done
settingsLoad ./assets/settings.defaults "$core_root/state/settings" || setupAbort "cannot read state/settings"

# --- 9. core-owned folders ---

testFail folders || setupAbort "creating the folders failed"
for setup_folder in deployments log mounts/nginx mounts/kratos sockets state/host-manager
do
  objectsFolder "$core_root" "$setup_folder" || setupAbort "cannot create $setup_folder"
done
# from here the install's output also goes to log/scripts.log (the questions and checks before it
# only to the terminal)
logCore "$core_root" setup.sh
setup_hd="$(settingsGet host_dir_repository_path)"
case "$setup_hd" in
  "$core_root"/*)
    objectsFolder "$core_root" "${setup_hd#"$core_root"/}" || setupAbort "cannot create $setup_hd"
    ;;
  *)
    # outside the core root: the installation was pointed at it, it isn't removed with the core
    mkdir -p "$setup_hd" || setupAbort "cannot create $setup_hd"
esac

# --- 10. prepare version, then the core-owned units and the secrets tmpfs ---

versionPrepare "$core_root" ./assets "$version" 0 0 || setupAbort "preparing $version failed"
testFail prepare || setupAbort "preparing $version failed"
setup_config="$core_root/$version_folder/config/systemd-units/core"
objectsDir "/mnt/$core_name" || setupAbort "cannot create /mnt/$core_name"
if [ "$(settingsGet autostart)" = "true" ]
then
  setup_mount_unit="$(systemd-escape --path --suffix=mount "/mnt/$core_name/secrets")"
  objectsFile "$host_systemd_path/$setup_mount_unit" 644 < "$setup_config/secrets.mount" || setupAbort "cannot write the mount unit"
  objectsFile "$host_systemd_path/$core_name-recover.service" 644 < "$setup_config/recover.service" || setupAbort "cannot write the recovery unit"
  systemctl daemon-reload || setupAbort "systemctl daemon-reload failed"
  for setup_unit in "$setup_mount_unit" "$core_name-recover.service"
  do
    objectsRecord "unit:$setup_unit" || setupAbort "cannot record $setup_unit"
    systemctl enable "$setup_unit" > /dev/null 2>&1 || setupAbort "enabling $setup_unit failed"
  done
else
  objectsRecord "mount:/mnt/$core_name/secrets" || setupAbort "cannot record the secrets tmpfs"
fi
coreMountSecrets || setupAbort "mounting the secrets tmpfs failed"
testFail units || setupAbort "setting up the core-owned units failed"

# --- 11. activate version ---

versionActivate "$core_root" "$version_folder" || setupAbort "activating $version failed"
testFail activate || setupAbort "activating $version failed"

# --- 12. success ---

{ testFail success && installRecordResult "$record" success; } || setupAbort "cannot record the install's success"
trap - INT TERM HUP
objects_record=""
say "installation of $version successful: $core_root"

# --- 13. start ---

# whether the core is meant to run (PLAN.md 9); a failure here doesn't fail the install, without the
# file autostart decides
if [ "$(setupGet start_core)" = "true" ]
then
  coreSetTarget "$core_root" running || say "warning: cannot write state/target_state" >&2
else
  coreSetTarget "$core_root" stopped || say "warning: cannot write state/target_state" >&2
fi
if [ "$(setupGet start_core)" = "true" ]
then
  say "starting the core ..."
  if ! coreStart "$core_root"
  then
    say "starting the core failed; the installation is complete, start it with $core_root/current/ctrl.sh start" >&2
  fi
fi

# --- 14. finish ---

lockRelease
say ""
say "control the core with: $core_root/current/ctrl.sh"
say "log into the web ui with:"
say "  user:     $(settingsGet core_usr)"
if [ "$auto" = "false" ]
then
  # never into the log
  logTerminalOnly "  password: $(settingsGet core_usr_pw)"
else
  say "  password: core_usr_pw in $core_root/state/settings"
fi
