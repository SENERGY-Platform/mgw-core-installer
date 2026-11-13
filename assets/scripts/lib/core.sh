#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# Version folder names (PLAN.md 4) and the shared building blocks "start core" and "stop core"
# (PLAN.md 8, 10a): starting the core means starting the host binaries, stopping it means stopping
# them. The core-manager starts the core containers when it starts and stops them when it stops (7).
#
# With systemd the host binaries are the service units in current/config/systemd-units/services.
# Without systemd they are started detached and recorded in state/pid (from the former
# lib/bin_ctrl.sh).
#
# Needs lib/settings.sh with the settings loaded (autostart, core_name, secrets_size), and
# lib/state.sh for the target state.

# host binaries in start order, with the base name of the file their output goes to
core_bins="SENERGY-Platform/mgw-container-engine-wrapper:ce_wrapper
SENERGY-Platform/mgw-host-manager:h_manager
SENERGY-Platform/mgw-core-manager:c_manager"

# how long a stopping host binary gets before SIGKILL: the core-manager stops the containers first
# (up to 2 minutes), as TimeoutStopSec in its unit
core_stop_wait=180

# prints the folder name of the version $1: every dot becomes an underscore (v1.2.3 -> v1_2_3,
# v0.33.0-beta2 -> v0_33_0-beta2, dev-<timestamp> stays). The name is part of the compose project
# name, which only allows lowercase letters, digits, "-" and "_"; anything else is refused.
versionFolder() {
  version_folder="$(printf '%s' "$1" | tr '.' '_')"
  case "$version_folder" in
    ""|*[!a-z0-9_-]*|[!a-z0-9]*)
      echo "invalid version '$1'" >&2
      return 1
  esac
  echo "$version_folder"
}

# prints the names of current's service units, one per line
coreUnits() {
  for core_unit in "$1/current/config/systemd-units/services"/*.service
  do
    if [ -f "$core_unit" ]
    then
      echo "${core_unit##*/}"
    fi
  done
}

# mounts the secrets tmpfs if it isn't mounted. Clears the plain directory underneath first (secrets
# written while it wasn't mounted); a mounted tmpfs is never cleared (PLAN.md 6).
coreMountSecrets() {
  core_secrets="/mnt/$(settingsGet core_name)/secrets"
  if [ "$(stat -f -c %T "$core_secrets" 2> /dev/null)" = "tmpfs" ]
  then
    return 0
  fi
  if ! mkdir -p "$core_secrets"
  then
    echo "cannot create '$core_secrets'" >&2
    return 1
  fi
  if ! find "$core_secrets" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  then
    echo "cannot clear '$core_secrets'" >&2
    return 1
  fi
  echo "mounting $core_secrets ..."
  if [ "$(settingsGet autostart)" = "true" ]
  then
    systemctl start "$(systemd-escape --path --suffix=mount "$core_secrets")"
    return
  fi
  mount -t tmpfs -o "nosuid,nodev,noexec,mode=1777,size=$(settingsGet secrets_size)" tmpfs "$core_secrets"
}

# starts the core of the core root $1: mounts the secrets tmpfs if needed, then starts the host
# binaries. An already running core is reported, not started twice.
coreStart() {
  if ! coreMountSecrets
  then
    return 1
  fi
  if [ "$(settingsGet autostart)" = "true" ]
  then
    core_units="$(coreUnits "$1")"
    if [ "$core_units" = "" ]
    then
      echo "no service units in '$1/current/config'" >&2
      return 1
    fi
    echo "starting $(echo "$core_units" | tr '\n' ' ')..."
    # shellcheck disable=SC2086 # one argument per unit
    systemctl start $core_units
    return
  fi
  coreStartBins "$1"
}

# stops the core of the core root $1. The secrets tmpfs stays mounted (PLAN.md 6).
coreStop() {
  if [ "$(settingsGet autostart)" = "true" ]
  then
    core_units="$(coreUnits "$1")"
    if [ "$core_units" = "" ]
    then
      return 0
    fi
    echo "stopping $(echo "$core_units" | tr '\n' ' ')..."
    # shellcheck disable=SC2086 # one argument per unit
    systemctl stop $core_units
    return
  fi
  coreStopBins "$1"
}

# returns 0 if the core of the core root $1 is running: every host binary (unit or process) is up
coreRunning() {
  if [ "$(settingsGet autostart)" = "true" ]
  then
    core_units="$(coreUnits "$1")"
    [ "$core_units" != "" ] || return 1
    for core_unit in ${core_units}
    do
      systemctl is-active --quiet "$core_unit" || return 1
    done
    return 0
  fi
  [ "$(coreMissingBins "$(coreListBins "$1")")" = "" ]
}

# --- without systemd ---

# the path of a host binary: through current, so a process can be matched by it
coreBinPath() {
  echo "$1/current/bin/$2/bin"
}

# prints the pid from the list $1 whose process runs the binary $2, returns 1 if none does. The binary
# has to be matched: after a reboot the pids in state/pid may belong to unrelated processes.
coreFindProc() {
  for core_pid in ${1}
  do
    if [ "$({ tr '\0' '\n' < "/proc/$core_pid/cmdline" | head -1; } 2> /dev/null)" = "$2" ]
    then
      echo "$core_pid"
      return 0
    fi
  done
  return 1
}

# prints the repo:pid list of the running host binaries of the core root $1, from state/pid
coreListBins() {
  core_running=""
  if [ -e "$1/state/pid" ]
  then
    core_pids="$(cat "$1/state/pid")"
    for core_item in ${core_bins}
    do
      core_repo="${core_item%%:*}"
      if core_pid="$(coreFindProc "$core_pids" "$(coreBinPath "$1" "$core_repo")")"
      then
        core_running="${core_running}$core_repo:$core_pid "
      fi
    done
  fi
  echo "$core_running"
}

# prints the host binaries missing from the repo:pid list $1
coreMissingBins() {
  core_missing=""
  for core_item in ${core_bins}
  do
    case " $1" in
      *" ${core_item%%:*}:"*)
        ;;
      *)
        core_missing="${core_missing}${core_item%%:*} "
    esac
  done
  echo "$core_missing"
}

# terminates the pids in $1 in this order and waits for each, SIGKILL after core_stop_wait seconds
coreKill() {
  for core_pid in ${1}
  do
    kill "$core_pid" 2> /dev/null
    core_waited=0
    while kill -0 "$core_pid" 2> /dev/null
    do
      if [ "$core_waited" -ge $((core_stop_wait * 10)) ]
      then
        echo "process $core_pid did not stop, sending SIGKILL ..." >&2
        kill -9 "$core_pid" 2> /dev/null
        break
      fi
      sleep 0.1
      core_waited=$((core_waited + 1))
    done
  done
}

# prints the pids of the repo:pid list $1 in reverse order (stop order)
coreReversePids() {
  core_rev=""
  for core_item in ${1}
  do
    core_rev="${core_item##*:} $core_rev"
  done
  echo "$core_rev"
}

# starts the host binaries of the core root $1 detached and records their pids in state/pid. setsid
# makes each a session leader without a controlling terminal, and the redirections replace the
# caller's streams, so the binaries outlive the shell, ssh session or cron job that started them.
# Descriptor 9 (the core's lock) is closed, or a binary would hold the lock for as long as it runs.
coreStartBins() {
  core_running="$(coreListBins "$1")"
  if [ -e "$1/state/pid" ]
  then
    if [ "$(coreMissingBins "$core_running")" = "" ]
    then
      echo "host binaries already running"
      return 0
    fi
    if [ "$core_running" != "" ]
    then
      echo "stopping an incomplete set of host binaries ..."
      coreKill "$(coreReversePids "$core_running")"
    fi
    if ! rm -f "$1/state/pid"
    then
      return 1
    fi
  fi
  echo "starting host binaries ..."
  for core_item in ${core_bins}
  do
    core_repo="${core_item%%:*}"
    # shellcheck disable=SC2016 # expanded by the inner shell
    setsid sh -c 'echo $$ >> "$4"; exec "$1" -config="$2" < /dev/null >> "$3" 2>&1' \
      sh "$(coreBinPath "$1" "$core_repo")" "$1/current/config/host-binaries/$core_repo/conf.json" \
      "$1/log/${core_item##*:}_out.log" "$1/state/pid" 9>&- 7>&- &
  done
  # the binaries record themselves asynchronously: wait until all are recorded and running, so the
  # next look at the core (status, a stop) sees them. Returns as soon as they are, gives up after 5s.
  core_waited=0
  while true
  do
    core_missing="$(coreMissingBins "$(coreListBins "$1")")"
    if [ "$core_missing" = "" ]
    then
      return 0
    fi
    if [ "$core_waited" -ge 50 ]
    then
      echo "host binaries not running: $core_missing(see the logs in $1/log)" >&2
      return 1
    fi
    sleep 0.1
    core_waited=$((core_waited + 1))
  done
}

# stops the host binaries of the core root $1 in reverse start order and removes state/pid
coreStopBins() {
  core_running="$(coreListBins "$1")"
  if [ "$core_running" != "" ]
  then
    echo "stopping host binaries ..."
    coreKill "$(coreReversePids "$core_running")"
  fi
  rm -f "$1/state/pid"
}

# returns 0 if any part of the core of the core root $1 runs (a unit or a host binary)
coreAnyRunning() {
  if [ "$(settingsGet autostart)" = "true" ]
  then
    for core_unit in $(coreUnits "$1")
    do
      systemctl is-active --quiet "$core_unit" && return 0
    done
    return 1
  fi
  [ "$(coreListBins "$1")" != "" ]
}

# recreates current's containers of the core root $1 (ctr-recreate, and after a settings change that
# affects the compose file). The core-manager's monitor would start new containers one by one,
# without the compose dependencies and without the one-shot migrations, so a running core is stopped
# first and started again afterwards: its core-manager runs compose start, in dependency order
# (m4-ctrl.md, finding 3). Volumes and networks are external and stay. $2 limits the compose call in
# seconds (0: no limit).
coreRecreate() {
  core_was_running=false
  if coreAnyRunning "$1"
  then
    core_was_running=true
    coreStop "$1" || return 1
  fi
  echo "recreating the containers ..."
  if ! dockerCompose "${2:-0}" -f "$1/current/config/container/docker-compose.yml" up --no-start --force-recreate --pull never --remove-orphans
  then
    echo "recreating the containers failed" >&2
    return 1
  fi
  if [ "$core_was_running" = "true" ]
  then
    coreStart "$1"
  fi
}

# --- the target state (PLAN.md 9, m5-update.md finding 5) ---

# the current boot's id; a reboot changes it
coreBootId() {
  cat /proc/sys/kernel/random/boot_id 2> /dev/null
}

# records in state/target_state of the core root $1 that the core is meant to be $2 (running or
# stopped), for this boot. Written by whoever starts or stops the core on purpose, before acting, so
# a failed start still records the intent. Needs lib/state.sh.
coreSetTarget() {
  recordClear core_target "state boot_id" ""
  recordSet core_target state "$2"
  recordSet core_target boot_id "$(coreBootId)"
  recordWrite "$1/state/target_state" core_target "state boot_id" ""
}

# prints whether the core of the core root $1 is meant to be running or stopped. An entry from
# before the last boot, or none: autostart decides, because a reboot starts a core with autostart
# and leaves one without it down.
coreTarget() {
  recordClear core_target "state boot_id" ""
  # shellcheck disable=SC2154 # core_target_* are set by recordLoad
  if recordLoad "$1/state/target_state" core_target "" 2> /dev/null && [ "$core_target_boot_id" = "$(coreBootId)" ]
  then
    case "$core_target_state" in
      running|stopped)
        echo "$core_target_state"
        return 0
    esac
  fi
  if [ "$(settingsGet autostart)" = "true" ]
  then
    echo running
  else
    echo stopped
  fi
}

# --- the point of no return (PLAN.md 13, S8) ---

# prints a mark of the host binaries' last start for the core root $1, to compare after a start
coreStartMark() {
  if [ "$(settingsGet autostart)" = "true" ]
  then
    for core_unit in $(coreUnits "$1")
    do
      printf '%s=%s ' "$core_unit" "$(systemctl show -p ExecMainStartTimestampMonotonic --value "$core_unit" 2> /dev/null)"
    done
    return
  fi
  echo none
}

# returns 0 if a host binary of the core root $1 started since the mark $2 (coreStartMark): the
# point of no return was passed (S8). With systemd a unit's main process start time changed; without,
# a pid was recorded in state/pid.
coreStartedSince() {
  if [ "$(settingsGet autostart)" = "true" ]
  then
    [ "$(coreStartMark "$1")" != "$2" ]
    return
  fi
  [ -s "$1/state/pid" ]
}
