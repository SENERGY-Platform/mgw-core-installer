#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# Controls an installed core (PLAN.md 8, m4-ctrl.md). Run as root through <core root>/current/ctrl.sh.
#
# Changing commands take the core's lock (waiting at most two seconds) and refuse if the core needs
# repair, pointing to restore.sh; ctrl.sh doesn't run recovery itself. status and help only read and
# take no lock.

# the libraries' variables are used across files, which shellcheck can't follow
# shellcheck disable=SC2034,SC2154

usage() {
  cat <<'USAGE'
usage: ctrl.sh [-y] <command>

  start          start the core (the host binaries; the core-manager starts the containers)
  stop           stop the core
  restart        stop, then start the core
  ctr-recreate   recreate the core's containers (a running core is stopped and started again)
  settings list [-a]       show the settings that can be changed, with -a also the fixed ones;
                           "(set)" marks the ones set for this core
  settings get <key>       show one setting
  settings set <key> <value>
                           change a setting and apply it
  settings reset <key>     go back to the version's default (only settings that follow the defaults)
  status         show the core's state, its last update and check, and who holds its lock
  help           show this help

  -y             answer yes to every confirmation
USAGE
}

assume_yes=false
while [ $# -gt 0 ]
do
  case "$1" in
    -y)
      assume_yes=true
      shift
      ;;
    *)
      break
  esac
done
command="$1"
[ $# -gt 0 ] && shift

case "$command" in
  help|-h|--help)
    usage
    exit 0
    ;;
  "")
    usage >&2
    exit 1
esac

# the script's own folder (assets/scripts), also when started through the link in the version folder
script_dir="$(dirname "$(readlink -f "$0")")"
for ctrl_lib in file settings state lock log host render reconcile net docker objects core version setup ctrl
do
  # shellcheck disable=SC1090
  . "$script_dir/lib/$ctrl_lib.sh" || exit 1
done

core_root=""
for ctrl_candidate in "$(dirname "$0")/.." "$script_dir/../../.."
do
  if [ -f "$ctrl_candidate/state/settings" ]
  then
    core_root="$(cd "$ctrl_candidate" && pwd -P)"
    break
  fi
done
if [ "$core_root" = "" ]
then
  echo "no core found: run ctrl.sh as <core root>/current/ctrl.sh" >&2
  exit 1
fi
if [ "$(id -u)" != "0" ]
then
  echo "root privileges required" >&2
  exit 1
fi
if ! settingsLoad "$script_dir/../settings.defaults" "$core_root/state/settings"
then
  exit 1
fi

# takes the lock and refuses if the core needs repair; $1 allows the command also then (stop)
ctrlBegin() {
  # the changing commands are logged, the reading ones aren't
  logCore "$core_root" "ctrl.sh"
  lockAcquire "$core_root/state/lock" ctrl.sh
  case $? in
    0)
      ;;
    2)
      exit 1
      ;;
    *)
      exit 1
  esac
  if ctrl_problem="$(ctrlProblem "$core_root")"
  then
    if [ "$1" = "always" ]
    then
      echo "note: the core needs repair ($ctrl_problem); run $(ctrlRestoreCommand "$core_root")" >&2
      return 0
    fi
    echo "the core needs repair: $ctrl_problem" >&2
    echo "run $(ctrlRestoreCommand "$core_root"); ctrl.sh $command is refused until then" >&2
    lockRelease
    exit 1
  fi
}

# prints the running state of the host binaries
runningState() {
  if coreRunning "$core_root"
  then
    echo running
    return
  fi
  if [ "$(settingsGet autostart)" = "true" ]
  then
    for unit in $(coreUnits "$core_root")
    do
      if systemctl is-active --quiet "$unit"
      then
        echo "partly running"
        return
      fi
    done
  elif [ "$(coreListBins "$core_root")" != "" ]
  then
    echo "partly running"
    return
  fi
  echo stopped
}

# prints a line about current's containers
containerState() {
  ctr_project="$(settingsGet core_name)_$(readlink "$core_root/current" 2> /dev/null)"
  if ! ctr_list="$(docker ps -a --filter "label=com.docker.compose.project=$ctr_project" --format '{{.Label "core_srv_oneshot"}} {{.State}}' 2> /dev/null)"
  then
    echo "unknown (docker not reachable)"
    return
  fi
  ctr_total="$(printf '%s\n' "$ctr_list" | grep -c '^ ')"
  ctr_running="$(printf '%s\n' "$ctr_list" | grep -c '^ running$')"
  echo "$ctr_running of $ctr_total running"
}

# asks the yes/no question $1; -y answers yes, without a terminal it fails
confirm() {
  if [ "$assume_yes" = "true" ]
  then
    return 0
  fi
  if ! [ -t 0 ]
  then
    echo "$1 - confirmation needed, run with -y" >&2
    return 1
  fi
  printf '%s (y/n): ' "$1"
  read -r confirm_answer
  [ "$confirm_answer" = "y" ]
}

# re-renders current's config from the loaded settings
renderCurrent() {
  render_folder="$(readlink "$core_root/current")"
  render_version="$(cat "$core_root/current/assets/version")"
  # the version's own static asset (images)
  # shellcheck disable=SC1091
  . "$core_root/current/assets/options" || return 1
  testFail render || return 1
  renderVersion "$core_root/$render_folder" "$core_root" "$render_version" "$render_folder"
}

# writes the core-owned units (the secrets mount and the recovery unit) from current's config
writeCoreUnits() {
  units_src="$core_root/current/config/systemd-units/core"
  fileWriteAtomic "$host_systemd_path/$(systemd-escape --path --suffix=mount "/mnt/$(settingsGet core_name)/secrets")" 644 < "$units_src/secrets.mount" &&
    fileWriteAtomic "$host_systemd_path/$(settingsGet core_name)-recover.service" 644 < "$units_src/recover.service"
}

# switches autostart to $1 (m4-ctrl.md, ctrl-commands.md): systemd can't take over processes it
# didn't start, and processes it started stay under its control, so the host binaries are stopped and
# started again in the new mode. The secrets tmpfs stays mounted throughout: on -> off removes the
# mount unit's file without stopping the unit, off -> on lets the new mount unit take over the mount.
switchAutostart() {
  switch_running=false
  if coreAnyRunning "$core_root"
  then
    switch_running=true
    coreStop "$core_root" || return 1
  fi
  settingsSet "$core_root/state/settings" autostart "$1" || return 1
  settingsLoad "$script_dir/../settings.defaults" "$core_root/state/settings" || return 1
  if ! renderCurrent
  then
    return 2
  fi
  switch_core="$(settingsGet core_name)"
  switch_mount="$(systemd-escape --path --suffix=mount "/mnt/$switch_core/secrets")"
  if [ "$1" = "false" ]
  then
    reconcileEtc "$core_root" || return 1
    objectsRemove "$core_root" "unit:$switch_core-recover.service" > /dev/null 2>&1
    rm -f "$host_systemd_path/$switch_core-recover.service"
    # disable removes the mount unit's links, not the mount; the file goes without stopping the unit
    systemctl disable "$switch_mount" > /dev/null 2>&1
    rm -f "$host_systemd_path/$switch_mount"
    systemctl daemon-reload
  else
    writeCoreUnits || return 1
    systemctl daemon-reload || return 1
    systemctl enable "$switch_mount" "$switch_core-recover.service" > /dev/null 2>&1 || return 1
    reconcileEtc "$core_root" || return 1
  fi
  if [ "$switch_running" = "true" ]
  then
    # the target state's fallback after a reboot changes with autostart, so it is written explicitly
    coreSetTarget "$core_root" running || echo "warning: cannot write state/target_state" >&2
    coreStart "$core_root" || return 1
  fi
}

# applies the change of the setting $1 of the kind $2, after the setting was written and rendered
applySetting() {
  case "$2" in
    recreate|port)
      coreRecreate "$core_root" 0
      ;;
    integration)
      reconcileEtc "$core_root" || return 1
      if [ "$1" = "advertise" ] && ! { systemctl reload avahi-daemon > /dev/null 2>&1 || avahi-daemon --reload > /dev/null 2>&1; }
      then
        echo "warning: avahi reload failed" >&2
      fi
      ;;
    secrets)
      if [ "$(settingsGet autostart)" = "true" ]
      then
        writeCoreUnits || return 1
        systemctl daemon-reload || return 1
      fi
      echo "the new size takes effect at the next reboot"
      ;;
  esac
}

# changes the setting $1 to $2, or resets it if $2 is empty and $3 is "reset"
changeSetting() {
  change_kind="$(ctrlSettingKind "$1")"
  case "$change_kind" in
    unknown)
      echo "unknown setting '$1'" >&2
      return 1
      ;;
    refused)
      echo "$1 can't be changed: $(ctrlRefusedReason "$1")" >&2
      return 1
  esac
  if [ "$3" = "reset" ]
  then
    if ! ctrlResettable "$1"
    then
      echo "$1 can't be reset: it was fixed for this core at the install; set a value instead" >&2
      return 1
    fi
    if ! settingsIsSet "$1"
    then
      echo "$1 has its default already"
      return 0
    fi
  else
    setupValidate "$1" "$2" || return 1
    if [ "$(settingsGet "$1")" = "$2" ]
    then
      echo "$1 is $2 already"
      return 0
    fi
  fi
  if [ "$change_kind" = "port" ] && setupPortInUse "$2"
  then
    echo "port $2 is in use" >&2
    return 1
  fi
  change_pkg=""
  if [ "$change_kind" = "integration" ] && [ "$2" = "true" ]
  then
    # shellcheck disable=SC1091
    . "$core_root/current/assets/options" || return 1
    eval "change_pkg=\$install_pkg_$1"
    change_pkg="$(setupMissingPkg "$change_pkg")"
    if [ "$change_pkg" != "" ] && ! confirm "$1 needs the package $change_pkg, install it?"
    then
      return 1
    fi
  fi
  if [ "$change_kind" = "autostart" ] && ! confirm "switching autostart stops and starts the core, continue?"
  then
    return 1
  fi
  ctrlBegin
  if [ "$change_pkg" != "" ]
  then
    # shellcheck disable=SC2086 # one argument per package
    if ! apt-get update || ! apt-get install -y $change_pkg
    then
      echo "installing $change_pkg failed" >&2
      lockRelease
      return 1
    fi
  fi
  change_was_set=false
  settingsIsSet "$1" && change_was_set=true
  change_old="$(settingsGet "$1")"
  if [ "$change_kind" = "autostart" ]
  then
    switchAutostart "$2"
    change_rc=$?
  else
    if [ "$3" = "reset" ]
    then
      settingsUnset "$core_root/state/settings" "$1"
    else
      settingsSet "$core_root/state/settings" "$1" "$2"
    fi || { lockRelease; return 1; }
    settingsLoad "$script_dir/../settings.defaults" "$core_root/state/settings" || { lockRelease; return 1; }
    change_rc=0
    renderCurrent || change_rc=2
  fi
  if [ $change_rc -eq 2 ]
  then
    # a failed render: the config is unchanged, so the old value goes back (m4-ctrl.md, finding 5)
    echo "rendering the new configuration failed, $1 stays $change_old" >&2
    if [ "$change_was_set" = "true" ]
    then
      settingsSet "$core_root/state/settings" "$1" "$change_old"
    else
      settingsUnset "$core_root/state/settings" "$1"
    fi
    lockRelease
    return 1
  fi
  if [ $change_rc -eq 0 ] && [ "$change_kind" != "autostart" ]
  then
    applySetting "$1" "$change_kind" || change_rc=1
  fi
  lockRelease
  if [ $change_rc -ne 0 ]
  then
    echo "$1 is changed, but applying it failed; repeating the command or ctr-recreate applies it" >&2
    return 1
  fi
  echo "$1 is now $(settingsGet "$1")"
}

secretsSize() {
  df -h --output=size "/mnt/$(settingsGet core_name)/secrets" 2> /dev/null | tail -1 | tr -d ' '
}

case "$command" in
  status)
    ctrlReport "$core_root" "$(runningState)" "$(containerState)" "$( [ "$(stat -f -c %T "/mnt/$(settingsGet core_name)/secrets" 2> /dev/null)" = tmpfs ] && secretsSize || echo "not")"
    ;;
  start)
    ctrlBegin
    coreSetTarget "$core_root" running || echo "warning: cannot write state/target_state" >&2
    coreStart "$core_root"
    rc=$?
    lockRelease
    exit $rc
    ;;
  stop)
    ctrlBegin always
    coreSetTarget "$core_root" stopped || echo "warning: cannot write state/target_state" >&2
    coreStop "$core_root"
    rc=$?
    lockRelease
    exit $rc
    ;;
  restart)
    ctrlBegin
    coreSetTarget "$core_root" running || echo "warning: cannot write state/target_state" >&2
    coreStop "$core_root" && coreStart "$core_root"
    rc=$?
    lockRelease
    exit $rc
    ;;
  settings)
    case "$1" in
      list)
        case "$2" in
          "")
            ctrlSettingsList
            ;;
          -a)
            ctrlSettingsList all
            ;;
          *)
            echo "usage: ctrl.sh settings list [-a]" >&2
            exit 1
        esac
        ;;
      get)
        if [ "$2" = "" ] || [ "$(ctrlSettingKind "$2")" = "unknown" ]
        then
          echo "unknown setting '$2'" >&2
          exit 1
        fi
        settingsGet "$2"
        ;;
      set)
        if [ $# -ne 3 ]
        then
          echo "usage: ctrl.sh settings set <key> <value>" >&2
          exit 1
        fi
        changeSetting "$2" "$3"
        ;;
      reset)
        if [ $# -ne 2 ]
        then
          echo "usage: ctrl.sh settings reset <key>" >&2
          exit 1
        fi
        changeSetting "$2" "" reset
        ;;
      *)
        usage >&2
        exit 1
    esac
    ;;
  ctr-recreate)
    ctrlBegin
    coreRecreate "$core_root" 0
    rc=$?
    lockRelease
    exit $rc
    ;;
  *)
    echo "unknown command '$command'" >&2
    usage >&2
    exit 1
esac
