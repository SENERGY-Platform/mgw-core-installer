#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# Updates a core to the newest release (PLAN.md 10, m5-update.md). One script in two roles:
#
#   <core root>/current/update.sh [-a]     stage one: the running version's code. Recovers an
#                                          interrupted update, checks for a new release (state/check),
#                                          downloads it into vX_Y_Z_tmp and hands over to stage two.
#                                          -a marks an automatic run (cron): it applies the retry limit
#                                          and never updates a dev version.
#   <core root>/vX_Y_Z_tmp/update.sh -stage=2 [-a]
#                                          stage two: the new version's code, internal. Inherits the
#                                          lock. The exit code is the only contract between the two
#                                          (S4).
#   assets/scripts/update.sh [-a] -path=<dir>
#                                          the old installer's hand-over to the migration (15)

# the libraries' variables are used across files, which shellcheck can't follow
# shellcheck disable=SC2034,SC2154

auto=false
stage=1
old_path=""
for arg in "$@"
do
  case "$arg" in
    -a)
      auto=true
      ;;
    -stage=2)
      stage=2
      ;;
    -path=*)
      old_path="${arg#-path=}"
      ;;
    -h)
      echo "usage: $0 [-a]"
      echo "  -a  automatic run (cron): applies the retry limit, never updates a dev version"
      exit 0
      ;;
    *)
      echo "unknown option '$arg'" >&2
      exit 1
  esac
done

if [ "$(id -u)" != "0" ]
then
  echo "root privileges required" >&2
  exit 1
fi

# the script's own folder (assets/scripts), also when started through the link in a version folder
script_dir="$(dirname "$(readlink -f "$0")")"
for update_lib in file settings state lock host semver render reconcile net docker objects core version setup update
do
  # shellcheck disable=SC1090
  . "$script_dir/lib/$update_lib.sh" || exit 1
done

# the old installer's hand-over (15): its stage one runs the new release's assets/scripts/update.sh
# with -path=<install dir>, which holds the old flat layout
if [ "$old_path" != "" ]
then
  if [ -e "$old_path/.settings" ] && ! [ -e "$old_path/current" ]
  then
    if [ -x "$script_dir/migration.sh" ]
    then
      exec "$script_dir/migration.sh" "$@"
    fi
    echo "this release can't migrate the installation in '$old_path' yet" >&2
    exit 1
  fi
  echo "'$old_path' isn't an installation of the old installer" >&2
  exit 1
fi

# the core root: this script is <core root>/<version folder>/update.sh, a link
core_root=""
for update_candidate in "$(dirname "$0")/.." "$script_dir/../../.."
do
  if [ -f "$update_candidate/state/settings" ]
  then
    core_root="$(cd "$update_candidate" && pwd -P)"
    break
  fi
done
if [ "$core_root" = "" ]
then
  echo "no core found: run update.sh as <core root>/current/update.sh" >&2
  exit 1
fi

if [ "$stage" = "2" ]
then
  # --- stage two (the new version's code, PLAN.md 10) ---

  record="$core_root/state/update"
  # this script runs from <core root>/vX_Y_Z_tmp, which is renamed to vX_Y_Z while it runs; nothing
  # below keeps a path into it
  new_folder="$(basename "$(dirname "$(dirname "$script_dir")")")"
  new_folder="${new_folder%_tmp}"
  new_version="$(cat "$script_dir/../version")"
  pull_limit=0
  ctr_limit=0
  if [ "$auto" = "true" ]
  then
    pull_limit="$docker_pull_limit"
    ctr_limit="$docker_ctr_limit"
  fi

  if ! lockInherited "$core_root/state/lock" update
  then
    lockAcquire "$core_root/state/lock" update || exit 1
  fi

  # the old version's effective settings: for the target state and stopping it
  if ! settingsLoad "$core_root/current/assets/settings.defaults" "$core_root/state/settings"
  then
    exit 1
  fi
  old_folder="$(readlink "$core_root/current")"
  from_version="$(cat "$core_root/current/assets/version" 2> /dev/null)"
  core_name="$(settingsGet core_name)"
  was_running=false
  [ "$(coreTarget "$core_root")" = "running" ] && was_running=true

  # records the step $1 (informational) and writes the record; returns 1 if it can't be written
  step() {
    updateSet step "$1"
    echo "$1 ..."
    updateRecordWrite "$record"
  }

  # a failure in the phase $1 at the step $2 (13); the handling per phase follows with the error
  # handling, until then the failure is recorded
  stageFail() {
    echo "the update failed in phase $1: $2" >&2
    updateSet result failed
    updateSet step "$2"
    updateSet finished "$(stateNow)"
    updateRecordWrite "$record"
    exit 1
  }

  # the first record, before anything is created (10, S2: without it the update can't start)
  recordClear upd "$state_update_fields" warning
  updateSet format "$state_format"
  updateSet writer "$new_folder"
  updateSet kind update
  updateSet result running
  updateSet phase preparing
  updateSet started "$(stateNow)"
  updateSet from_version "$from_version"
  updateSet to_version "$new_version"
  updateSet old_folder "$old_folder"
  updateSet new_folder "$new_folder"
  updateSet was_running "$was_running"
  updateSet old_project "${core_name}_$old_folder"
  if ! step "preparing $new_version"
  then
    echo "cannot write $record, not updating" >&2
    objectsRemove "$core_root" "folder:${new_folder}_tmp"
    exit 1
  fi
  # a manual run resets the retry count (G8)
  if [ "$auto" != "true" ]
  then
    attemptsReset "$core_root/state/attempts" "$new_folder" || recordWarn upd "could not reset state/attempts"
  fi

  # B: preparation, the old core untouched
  versionBuild "$core_root" "$new_version" "$pull_limit" "$ctr_limit" pin
  build_rc=$?
  [ $build_rc -eq 0 ] || stageFail B "preparing $new_version (exit code $build_rc)"
  testFail prepare || stageFail B "preparing $new_version"
  updateSet phase switching
  step "switching to $new_version" || stageFail B "recording the switch"

  # C: switching; versionBuild left the new version's settings loaded, autostart and the units are
  # the same for stopping the old one
  testFail stop || stageFail C "stopping $old_folder"
  coreStop "$core_root" || stageFail C "stopping $old_folder"
  # a safety net if the old core-manager didn't stop its containers (e.g. it had crashed)
  dockerCompose "$ctr_limit" -f "$core_root/$old_folder/config/container/docker-compose.yml" stop > /dev/null 2>&1 ||
    stageFail C "stopping the containers of $old_folder"
  versionActivate "$core_root" "$new_folder" || stageFail C "activating $new_folder"
  [ "$version_warning" = "" ] || recordWarn upd "$version_warning"
  testFail activate || stageFail C "activating $new_folder"

  # D: starting, the point of no return (only if the core was meant to run)
  if [ "$was_running" = "true" ]
  then
    updateSet phase starting
    step "starting $new_version" || stageFail C "recording the start"
    coreStart "$core_root" || stageFail D "starting $new_version"
  fi

  # the final record, then the cleanup (E): an interrupted cleanup leaves a final record
  updateSet result success
  updateSet phase "done"
  updateSet finished "$(stateNow)"
  step "cleaning up" || stageFail C "recording the success"
  attemptsReset "$core_root/state/attempts" "$new_folder" > /dev/null 2>&1
  cleanup_out="$(updateCleanup "$core_root")"
  if [ "$cleanup_out" != "" ]
  then
    printf '%s\n' "$cleanup_out" | while IFS= read -r cleanup_line
    do
      echo "warning: $cleanup_line" >&2
    done
    # a heredoc, not a pipe: the loop must run in this shell to keep the warnings
    while IFS= read -r cleanup_line
    do
      recordWarn upd "$cleanup_line"
    done <<CLEANUP
$cleanup_out
CLEANUP
    updateSet step "done, the cleanup left something behind"
  else
    updateSet step "done"
  fi
  updateRecordWrite "$record" || echo "warning: cannot write $record" >&2
  echo "updated to $new_version"
  exit 0
fi

# --- stage one (the running version's code) ---

check_file="$core_root/state/check"

if ! settingsLoad "$script_dir/../settings.defaults" "$core_root/state/settings"
then
  exit 1
fi
core_name="$(settingsGet core_name)"
work="/tmp/$core_name"

# ends stage one with the check record $1 (result), $2 (version), $3 (step) and exit code $4. A
# check record that can't be written fails the run (S2).
finish() {
  if ! updateCheckRecord "$check_file" "$1" "$2" "$3" ${warnings:+"$warnings"}
  then
    echo "cannot write $check_file" >&2
    exit 1
  fi
  exit "$4"
}
warnings=""

# S1: a held lock refuses the run; it records nothing (the holder's record is the holder's)
lockAcquire "$core_root/state/lock" update
case $? in
  0)
    ;;
  *)
    exit 1
esac

# G5: an interrupted update or an unfinished install is resolved first, by the same recovery the boot
# unit runs, under this lock
if ! "$script_dir/recover.sh"
then
  echo "the recovery failed or removed an unfinished install; not updating" >&2
  finish failed "" "recovering before the update" 1
fi
lockWriteHolder "$core_root/state/lock" update "$$"

current_version="$(cat "$core_root/current/assets/version" 2> /dev/null)"
if [ "$current_version" = "" ]
then
  finish failed "" "reading the current version" 1
fi
case "$current_version" in
  dev-*)
    if [ "$auto" = "true" ]
    then
      echo "$current_version is a dev version, automatic runs don't update it"
      finish skipped "" "automatic runs don't update the dev version $current_version" 0
    fi
    # a manual run updates a dev version to the newest release
    compare_version="v0.0.0"
    ;;
  *)
    compare_version="$current_version"
esac

echo "checking for a new release ..."
if ! mkdir -p "$work" || ! githubReleases "$update_repo" "$work/releases.json"
then
  finish failed "" "checking for a new release" 1
fi
allow_beta="$(settingsGet allow_beta)"
[ "$allow_beta" = "true" ] || allow_beta=false
new_version="$(updatePickRelease "$work/releases.json" "$compare_version" "$allow_beta")"
if [ "$new_version" = "" ]
then
  echo "$current_version is up to date"
  rm -rf "$work"
  finish up_to_date "" "" 0
fi
if ! new_folder="$(versionFolder "$new_version")"
then
  finish failed "$new_version" "reading the version $new_version" 1
fi

# G8: an automatic run skips a version that failed too often; a manual run doesn't
limit="$(settingsGet update_retry_limit)"
if [ "$auto" = "true" ] && attemptsLimitReached "$core_root/state/attempts" "$new_folder" "${limit:-3}"
then
  echo "$new_version failed $limit times, automatic updates skip it; update.sh without -a tries again"
  rm -rf "$work"
  finish skipped "$new_version" "$new_version failed $limit times" 0
fi

echo "updating $current_version to $new_version ..."
# S2: a check record that can't be written stops the update before anything is downloaded
if ! updateCheckRecord "$check_file" update_available "$new_version" ""
then
  echo "cannot write $check_file" >&2
  exit 1
fi

# A: download and extract the release, create vX_Y_Z_tmp; a failure removes both
if ! rm -rf "$work" || ! mkdir -p "$work/extract"
then
  finish failed "$new_version" "preparing $work" 1
fi
if ! githubRelease "$update_repo" "$new_version" "$work/release.json" ||
  ! asset_url="$(githubAssetUrl "$work/release.json" "mgw_core_installer_$new_version.tar.gz")" ||
  ! netDownload "$asset_url" "$work/release.tar.gz"
then
  rm -rf "$work"
  finish failed "$new_version" "downloading release $new_version" 1
fi
if ! tar -xzf "$work/release.tar.gz" -C "$work/extract" || ! [ -f "$work/extract/assets/scripts/update.sh" ]
then
  rm -rf "$work"
  finish failed "$new_version" "extracting release $new_version" 1
fi
if ! versionCreate "$core_root" "$work/extract/assets" "$new_version"
then
  rm -rf "$work" "$core_root/${new_folder}_tmp"
  finish failed "$new_version" "creating ${new_folder}_tmp" 1
fi
if ! rm -rf "$work"
then
  warnings="could not delete $work"
fi

# stage two: the new version's code, inheriting the lock (fd 9, MGW_LOCK_HELD). Stage one doesn't
# release the lock afterwards: the release would apply to stage two's as well. It just exits.
stage2_args="-stage=2"
[ "$auto" = "true" ] && stage2_args="$stage2_args -a"
# shellcheck disable=SC2086 # the arguments are words
"$core_root/${new_folder}_tmp/update.sh" $stage2_args
stage2_rc=$?
if [ $stage2_rc -ne 0 ]
then
  # S4: stage one only knows the exit code; state/update (if written) has the details
  finish failed "$new_version" "the update script of $new_version failed (exit code $stage2_rc), see state/update" "$stage2_rc"
fi
finish update_available "$new_version" "" 0
