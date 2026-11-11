#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# The parts of ctrl.sh that don't need docker or systemd: the state check before a changing command
# and the status report (PLAN.md 8, m4-ctrl.md).
#
# ctrl.sh doesn't run recovery. Before a changing command it checks the core's records and refuses if
# the core needs repair, pointing to restore.sh, which recovers first (10b).
#
# Needs lib/settings.sh (loaded), lib/state.sh, lib/lock.sh.

# the record variables are set by recordLoad through eval
# shellcheck disable=SC2154

# prints why the core of the core root $1 needs repair, nothing if it doesn't. Meant to be called
# under the lock: a record saying "running" while this process holds the lock was left by a writer
# that is gone. Returns 0 if it needs repair.
ctrlProblem() {
  recordClear ctrl_rst "result" ""
  if recordLoad "$1/state/restore" ctrl_rst "" 2> /dev/null && [ "$ctrl_rst_result" != "success" ]
  then
    echo "a restore didn't finish (result '${ctrl_rst_result:-unknown}')"
    return 0
  fi
  recordClear ctrl_inst "result" ""
  if recordLoad "$1/state/install" ctrl_inst "" 2> /dev/null && [ "$ctrl_inst_result" != "success" ]
  then
    echo "the install of this core didn't finish (result '${ctrl_inst_result:-unknown}')"
    return 0
  fi
  recordClear ctrl_upd "$state_update_fields" warning
  recordLoad "$1/state/update" ctrl_upd warning 2> /dev/null
  case $? in
    2)
      echo "its update record state/update can't be read"
      return 0
  esac
  if [ "$ctrl_upd_recovery_failed" = "true" ]
  then
    echo "the recovery of an interrupted update failed"
    return 0
  fi
  if [ "$ctrl_upd_result" = "running" ]
  then
    echo "an update was interrupted (from ${ctrl_upd_from_version:-?} to ${ctrl_upd_to_version:-?}, phase ${ctrl_upd_phase:-?})"
    return 0
  fi
  return 1
}

# prints the restore.sh to run for the core root $1: current's, or after a failed restore the copy it
# left in <core root>/.restore, when current is gone
ctrlRestoreCommand() {
  if ! [ -e "$1/current/restore.sh" ] && [ -x "$1/.restore/assets/scripts/restore.sh" ]
  then
    echo "$1/.restore/assets/scripts/restore.sh -path=$1"
  else
    echo "$1/current/restore.sh"
  fi
}

# prints the report about the core root $1 (status), reading only. $2 is the running state ("running",
# "stopped", "partly running"), $3 a line about the containers, $4 the current tmpfs size; they come
# from docker and systemd, which the caller asks.
ctrlReport() {
  ctrl_folder="$(readlink "$1/current" 2> /dev/null)"
  ctrl_version="$(cat "$1/current/assets/version" 2> /dev/null)"
  echo "core:        $(settingsGet core_name) (core id $(settingsGet core_id))"
  echo "core root:   $1"
  echo "version:     ${ctrl_version:-unknown} (${ctrl_folder:-no current version})"
  echo "autostart:   $(settingsGet autostart)"
  echo "running:     $2"
  echo "containers:  $3"
  echo "secrets:     $4 mounted, $(settingsGet secrets_size) configured"
  echo "lock:        $(lockDescribe "$1/state/lock")"
  recordClear ctrl_upd "$state_update_fields" warning
  if recordLoad "$1/state/update" ctrl_upd warning 2> /dev/null
  then
    echo "last update: ${ctrl_upd_result:-?} (${ctrl_upd_kind:-update} ${ctrl_upd_from_version:-?} -> ${ctrl_upd_to_version:-?}, started ${ctrl_upd_started:-?}, finished ${ctrl_upd_finished:--})"
    [ "$ctrl_upd_rolled_back" = "true" ] && echo "             rolled back to the previous version"
    [ "$ctrl_upd_interrupted" = "true" ] && echo "             interrupted, recovered later"
    [ "$ctrl_upd_result" = "failed" ] && [ "$ctrl_upd_step" != "" ] && echo "             step: $ctrl_upd_step"
    if [ "$ctrl_upd_warning" != "" ]
    then
      printf '%s\n' "$ctrl_upd_warning" | sed 's/^/             warning: /'
    fi
  else
    echo "last update: none"
  fi
  recordClear ctrl_chk "$state_check_fields" warning
  if recordLoad "$1/state/check" ctrl_chk warning 2> /dev/null
  then
    echo "last check:  ${ctrl_chk_check_result:-?} at ${ctrl_chk_check_time:-?}${ctrl_chk_check_version:+ (found $ctrl_chk_check_version)}"
  else
    echo "last check:  none"
  fi
  # what a changing command would refuse: only meaningful while nobody holds the lock
  if ! lockHeld "$1/state/lock" && ctrl_problem="$(ctrlProblem "$1")"
  then
    echo ""
    echo "the core needs repair: $ctrl_problem"
    echo "run $(ctrlRestoreCommand "$1")"
  fi
}

# prints what changing the setting $1 involves (m4-ctrl.md, finding 4):
#   none         only stored (allow_beta, update_retry_limit)
#   recreate     re-render, recreate the containers (the container settings)
#   port         the new port must be free; re-render, recreate (gateway_port)
#   integration  package if missing, re-render, reconcile (logrotate, cron, advertise)
#   secrets      re-render, rewrite the mount unit; effective at the next reboot (secrets_size)
#   autostart    the switch between systemd services and detached processes
#   refused      the core's identity, its place on the host, its credentials, its subnets
#   unknown      no setting of this version
ctrlSettingKind() {
  case "$1" in
    allow_beta|update_retry_limit)
      echo none
      ;;
    *_log_level|*_delay|module_manager_http_access_log)
      echo recreate
      ;;
    gateway_port)
      echo port
      ;;
    logrotate|cron|advertise)
      echo integration
      ;;
    secrets_size)
      echo secrets
      ;;
    autostart)
      echo autostart
      ;;
    *)
      if settingsKnown "$1"
      then
        echo refused
      else
        echo unknown
      fi
  esac
}

# prints why the setting $1 can't be changed with ctrl.sh
ctrlRefusedReason() {
  case "$1" in
    core_id|core_name|stack_name)
      echo "it is the core's identity: its volumes, networks, units and files carry it"
      ;;
    subnet_*)
      echo "the subnets are part of the core's existing docker networks"
      ;;
    *_pw|core_usr)
      echo "the credentials are stored in the core's databases"
      ;;
    host_dir_repository_path)
      echo "the module repository's location is part of the existing containers and modules"
      ;;
    *)
      echo "this version doesn't support changing it"
  esac
}

# returns 0 if the setting $1 may be reset to its default: only settings that float with the version's
# defaults; the pinned ones (8) keep the value the install wrote
ctrlResettable() {
  case "$(ctrlSettingKind "$1")" in
    none|recreate)
      return 0
  esac
  return 1
}

# prints the effective settings, one "key=value" per line, "(set)" after the ones from state/settings,
# passwords hidden
ctrlSettingsList() {
  for ctrl_key in ${settings_keys}
  do
    ctrl_value="$(settingsGet "$ctrl_key")"
    case "$ctrl_key" in
      *_pw)
        [ "$ctrl_value" != "" ] && ctrl_value="(hidden)"
    esac
    if settingsIsSet "$ctrl_key"
    then
      echo "$ctrl_key=$ctrl_value (set)"
    else
      echo "$ctrl_key=$ctrl_value"
    fi
  done
}
