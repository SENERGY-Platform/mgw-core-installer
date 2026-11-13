#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# Repairs a broken core (PLAN.md 10b, m6-restore.md). The one repair command users run; recover.sh is
# internal (see PLAN.md 10b, "Recover and restore: the difference").
#
#   <core root>/current/restore.sh [options]          restores the version of that folder
#   ./restore.sh -path=<core root> [options]          from a release archive: restores its version
#
#   -y            answer yes to the confirmation
#   -start        start the core afterwards, whatever its target state says
#   -downgrade    allow restoring a version older than the one the core ran
#   -s=<file>     a copy of state/settings, for a core root that is lost (the volumes survived)
#
# First, if the records show an unfinished install or an interrupted update, the recovery handles it
# (no download, nothing rebuilt). Otherwise restore.sh rebuilds the version onto the core's existing
# data: it reuses every core-owned object that exists, recreates missing ones and never removes data.
# It records itself in state/restore; state/update keeps the cause of a failed update.

# the libraries' variables are used across files, which shellcheck can't follow
# shellcheck disable=SC2034,SC2154

usage() {
  sed -n '7,15p' "$0" | sed 's/^# \{0,1\}//'
}

core_root=""
settings_file=""
assume_yes=false
start=false
downgrade=false
for arg in "$@"
do
  case "$arg" in
    -path=*)
      core_root="${arg#-path=}"
      ;;
    -s=*)
      settings_file="${arg#-s=}"
      ;;
    -y)
      assume_yes=true
      ;;
    -start)
      start=true
      ;;
    -downgrade)
      downgrade=true
      ;;
    -h)
      usage
      exit 0
      ;;
    *)
      echo "unknown option '$arg'" >&2
      usage >&2
      exit 1
  esac
done

if [ "$(id -u)" != "0" ]
then
  echo "root privileges required" >&2
  exit 1
fi

# the script's own folder (assets/scripts): its version is the one restored
script_dir="$(dirname "$(readlink -f "$0")")"
assets_dir="$(cd "$script_dir/.." && pwd -P)"
for restore_lib in file settings state lock log host semver render reconcile net docker objects core version update setup
do
  # shellcheck disable=SC1090
  . "$script_dir/lib/$restore_lib.sh" || exit 1
done
target_version="$(cat "$assets_dir/version" 2> /dev/null)"
target_version="${target_version:-dev-$(date +%s)}"
if ! target_folder="$(versionFolder "$target_version")"
then
  exit 1
fi

# the core root: -path, or the version folder this script is linked from
if [ "$core_root" = "" ]
then
  if [ -f "$(dirname "$0")/../state/settings" ]
  then
    core_root="$(dirname "$0")/.."
  else
    echo "no core found: run restore.sh as <core root>/current/restore.sh, or with -path=<core root>" >&2
    exit 1
  fi
fi
case "$core_root" in
  /*|./*|../*)
    ;;
  *)
    core_root="./$core_root"
esac
if [ -e "$core_root/.settings" ] && ! [ -e "$core_root/current" ]
then
  echo "'$core_root' is an installation of the old installer; its update.sh migrates it" >&2
  exit 1
fi

# the settings: state/settings, or a backup copy for a lost core root (-s)
lost_root=false
if [ "$settings_file" != "" ]
then
  if [ -e "$core_root/state/settings" ]
  then
    echo "'$core_root' has its state/settings; -s is only for a core root that is lost" >&2
    exit 1
  fi
  if ! [ -r "$settings_file" ]
  then
    echo "cannot read '$settings_file'" >&2
    exit 1
  fi
  lost_root=true
  settings_source="$settings_file"
elif [ -f "$core_root/state/settings" ]
then
  settings_source="$core_root/state/settings"
else
  echo "'$core_root' has no state/settings: without it the core is lost (its identity and credentials" >&2
  echo "are only there); give a copy from a backup with -s=<file>" >&2
  exit 1
fi
if ! settingsLoad "$assets_dir/settings.defaults" "$settings_source"
then
  exit 1
fi
for restore_key in core_id core_name stack_name core_usr_pw core_db_pw core_db_root_pw
do
  if ! settingsIsSet "$restore_key" || [ "$(settingsGet "$restore_key")" = "" ]
  then
    echo "$settings_source lacks $restore_key; it isn't the settings of a core" >&2
    exit 1
  fi
done
core_name="$(settingsGet core_name)"
core_id="$(settingsGet core_id)"
stack_name="$(settingsGet stack_name)"
if [ "$lost_root" = "true" ]
then
  mkdir -p "$core_root" || exit 1
fi
core_root="$(cd "$core_root" && pwd -P)" || exit 1
if [ "${core_root##*/}" != "$core_id" ]
then
  echo "warning: the core root '$core_root' isn't named after the core id $core_id" >&2
fi

# --- the lock and the records ---

if ! mkdir -p "$core_root/state" "$core_root/log"
then
  exit 1
fi
logCore "$core_root" restore.sh
lockAcquire "$core_root/state/lock" restore.sh || exit 1
record="$core_root/state/update"

# 1. the recovery first (m6-restore.md, finding 1): only if the records show something to recover
recordClear inst "result" ""
recordClear upd "$state_update_fields" warning
install_unfinished=false
if recordLoad "$core_root/state/install" inst "" 2> /dev/null && [ "$inst_result" != "success" ]
then
  install_unfinished=true
fi
recordLoad "$record" upd warning 2> /dev/null
if { [ "$install_unfinished" = "true" ] || [ "$upd_result" = "running" ]; } && [ "$upd_recovery_failed" != "true" ] &&
  [ -x "$core_root/current/assets/scripts/recover.sh" ]
then
  echo "an interrupted operation is recorded, trying the recovery first ..."
  if "$core_root/current/assets/scripts/recover.sh" -by=restore.sh
  then
    echo "recovered, nothing to rebuild"
    lockRelease
    exit 0
  fi
  if ! [ -e "$core_root/state/settings" ]
  then
    echo "the unfinished install was removed; install the core again with setup.sh"
    exit 0
  fi
  echo "the recovery wasn't possible, rebuilding instead"
  lockWriteHolder "$core_root/state/lock" restore.sh "$$"
  recordClear upd "$state_update_fields" warning
  recordLoad "$record" upd warning 2> /dev/null
fi

# --- what the rebuild will do, and the confirmation ---

current_folder="$(readlink "$core_root/current" 2> /dev/null)"
current_version="$(cat "$core_root/current/assets/version" 2> /dev/null)"
current_version="${current_version:-$upd_to_version}"
if [ "$current_version" != "" ] && semverValid "$current_version" && semverValid "$target_version" &&
  semverLess "$target_version" "$current_version"
then
  echo "$target_version is older than $current_version, the version the core ran. Data migrations of the" >&2
  echo "newer version aren't undone; the older version may not work with that data." >&2
  if [ "$downgrade" != "true" ]
  then
    echo "not restoring; to restore it anyway, add -downgrade" >&2
    lockRelease
    exit 1
  fi
fi
# the volumes the version uses, from its compose template; a missing one has lost its data
missing_volumes=""
# shellcheck disable=SC2013,SC2016 # names without spaces; ${STACK_NAME} is the template's literal text
for volume in $(grep -o 'name: ${STACK_NAME}_[a-z0-9_-]*' "$assets_dir/templates/container/docker-compose.yml.tmpl" | sed 's/^name: ${STACK_NAME}//')
do
  if ! docker volume inspect "$stack_name$volume" > /dev/null 2>&1
  then
    missing_volumes="${missing_volumes}$stack_name$volume "
  fi
done

echo "restore.sh rebuilds this core:"
echo "  core:      $core_name (core id $core_id)"
echo "  core root: $core_root"
echo "  version:   $target_version, from $assets_dir"
echo "             (the core ran ${current_version:-an unknown version})"
echo "The core is stopped, its version folder and containers are rebuilt from scratch; its data"
echo "(volumes, deployments, settings) is kept. Changes a missing version made can't be undone."
for volume in ${missing_volumes}
do
  echo "  the volume $volume is missing: its data is lost, it is created empty"
done
if [ "$assume_yes" != "true" ]
then
  if ! [ -t 0 ]
  then
    echo "confirmation needed, run with -y" >&2
    lockRelease
    exit 1
  fi
  printf 'restore it? (y/n): '
  read -r answer
  if [ "$answer" != "y" ]
  then
    echo "nothing changed"
    lockRelease
    exit 0
  fi
fi

# --- the rebuild ---

restore_file="$core_root/state/restore"
recordClear rst "$state_restore_fields" warning
recordSet rst format "$state_format"
recordSet rst result running
recordSet rst version "$target_version"
recordSet rst from_version "$current_version"
recordSet rst started "$(stateNow)"

# records the step $1 of the restore
restoreStep() {
  echo "$1 ..."
  recordSet rst step "$1"
  recordWrite "$restore_file" rst "$state_restore_fields" warning || echo "warning: cannot write $restore_file" >&2
}

# a failure: recorded, the core left as it is; running restore.sh again repairs it (G6). Once the
# version folder may be gone, the copy of the assets in <core root>/.restore has a restore.sh.
restoreFail() {
  if [ -x "$core_root/.restore/assets/scripts/restore.sh" ]
  then
    echo "the restore failed: $1; run $core_root/.restore/assets/scripts/restore.sh -path=$core_root again" >&2
  else
    echo "the restore failed: $1; run restore.sh again" >&2
  fi
  recordSet rst result failed
  recordSet rst step "$1"
  recordSet rst finished "$(stateNow)"
  recordWrite "$restore_file" rst "$state_restore_fields" warning
  lockRelease
  exit 1
}

if [ "$lost_root" = "true" ]
then
  restoreStep "restoring state/settings from $settings_file"
  fileWriteAtomic "$core_root/state/settings" 600 < "$settings_file" || restoreFail "writing state/settings"
fi
for volume in ${missing_volumes}
do
  recordWarn rst "the volume $volume was missing and was created empty"
done
was_target="$(coreTarget "$core_root")"

restoreStep "stopping the core"
for unit_file in "$host_systemd_path/$core_name"-*.service
do
  case "${unit_file##*/}" in
    "$core_name-recover.service")
      continue
  esac
  if [ -e "$unit_file" ] || [ -L "$unit_file" ]
  then
    systemctl stop "${unit_file##*/}" > /dev/null 2>&1
  fi
done
if [ -e "$core_root/state/pid" ] && [ -d "$core_root/current" ]
then
  coreStopBins "$core_root"
fi
docker ps -q --filter "label=mgw_cid=$core_id" --filter "label=core_srv=true" | xargs -r docker stop > /dev/null 2>&1

restoreStep "copying the assets of $target_version"
# in the core root, not /tmp: it is the restore.sh to run again if this one fails after the version
# folder is gone, also after a reboot. Started from it, the copy is kept as it is.
work="$core_root/.restore"
if [ "$assets_dir" != "$work/assets" ]
then
  if ! rm -rf "$work" || ! mkdir -p "$work" || ! cp -a "$assets_dir" "$work/assets"
  then
    restoreFail "copying the assets of $target_version"
  fi
fi
# the folder the assets came from may be the one rebuilt
rm -f "$core_root/current"
objectsRemove "$core_root" "project:${core_name}_$target_folder" 2> /dev/null || restoreFail "removing the containers of $target_folder"
for folder in "$target_folder" "${target_folder}_tmp"
do
  objectsRemove "$core_root" "folder:$folder" || restoreFail "removing $core_root/$folder"
done

restoreStep "recreating missing folders"
for folder in deployments log mounts/nginx mounts/kratos sockets state/host-manager
do
  mkdir -p "$core_root/$folder" || restoreFail "creating $folder"
done
mkdir -p "$(settingsGet host_dir_repository_path)" || restoreFail "creating the module repository"

restoreStep "building $target_version"
versionCreate "$core_root" "$work/assets" "$target_version" || restoreFail "building $target_version"
versionBuild "$core_root" "$target_version" 0 0 pin || restoreFail "building $target_version"
testFail restore || restoreFail "building $target_version"

restoreStep "the core-owned units and the secrets tmpfs"
if [ "$(settingsGet autostart)" = "true" ]
then
  units_src="$core_root/$target_folder/config/systemd-units/core"
  mount_unit="$(systemd-escape --path --suffix=mount "/mnt/$core_name/secrets")"
  if ! fileWriteAtomic "$host_systemd_path/$mount_unit" 644 < "$units_src/secrets.mount" ||
    ! fileWriteAtomic "$host_systemd_path/$core_name-recover.service" 644 < "$units_src/recover.service" ||
    ! systemctl daemon-reload || ! systemctl enable "$mount_unit" "$core_name-recover.service" > /dev/null 2>&1
  then
    restoreFail "writing the core-owned units"
  fi
fi
if ! mkdir -p "/mnt/$core_name" || ! coreMountSecrets
then
  restoreFail "mounting the secrets tmpfs"
fi

restoreStep "activating $target_version"
versionActivate "$core_root" "$target_folder" || restoreFail "activating $target_folder"
[ "$version_warning" = "" ] || recordWarn rst "$version_warning"

# state/update keeps the cause of a failed update; a record that blocks the core is only marked
# (m6-restore.md, finding 3)
if [ "$upd_result" = "running" ] || [ "$upd_recovery_failed" = "true" ]
then
  recordSavePrevious "$record" "$record.previous" || recordWarn rst "could not keep state/update as state/update.previous"
  recordSet upd result failed
  recordSet upd recovery_failed ""
  recordSet upd restored true
  [ "$upd_finished" != "" ] || recordSet upd finished "$(stateNow)"
  updateRecordWrite "$record" || recordWarn rst "could not mark state/update as restored"
fi

restoreStep "cleaning up"
cleanup_out="$(updateCleanup "$core_root")"
while IFS= read -r cleanup_line
do
  [ "$cleanup_line" = "" ] || recordWarn rst "$cleanup_line"
done <<CLEANUP
$cleanup_out
CLEANUP

if [ "$start" = "true" ] || [ "$was_target" = "running" ]
then
  restoreStep "starting the core"
  coreSetTarget "$core_root" running || recordWarn rst "could not write state/target_state"
  coreStart "$core_root" || restoreFail "starting the core"
else
  coreSetTarget "$core_root" stopped || recordWarn rst "could not write state/target_state"
fi

rm -rf "$work"
recordSet rst result success
recordSet rst finished "$(stateNow)"
recordSet rst step "done"
recordWrite "$restore_file" rst "$state_restore_fields" warning || echo "warning: cannot write $restore_file" >&2
lockRelease
echo "the core was restored to $target_version"
