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
for ctrl_lib in file settings state lock host render reconcile net docker objects core version setup ctrl
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
      echo "note: the core needs repair ($ctrl_problem); run $core_root/current/restore.sh" >&2
      return 0
    fi
    echo "the core needs repair: $ctrl_problem" >&2
    echo "run $core_root/current/restore.sh; ctrl.sh $command is refused until then" >&2
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

secretsSize() {
  df -h --output=size "/mnt/$(settingsGet core_name)/secrets" 2> /dev/null | tail -1 | tr -d ' '
}

case "$command" in
  status)
    ctrlReport "$core_root" "$(runningState)" "$(containerState)" "$( [ "$(stat -f -c %T "/mnt/$(settingsGet core_name)/secrets" 2> /dev/null)" = tmpfs ] && secretsSize || echo "not")"
    ;;
  start)
    ctrlBegin
    coreStart "$core_root"
    rc=$?
    lockRelease
    exit $rc
    ;;
  stop)
    ctrlBegin always
    coreStop "$core_root"
    rc=$?
    lockRelease
    exit $rc
    ;;
  restart)
    ctrlBegin
    coreStop "$core_root" && coreStart "$core_root"
    rc=$?
    lockRelease
    exit $rc
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
