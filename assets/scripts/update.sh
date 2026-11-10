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
  echo "stage two isn't implemented in this version" >&2
  exit 1
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
