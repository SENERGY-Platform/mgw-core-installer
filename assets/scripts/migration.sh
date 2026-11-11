#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# Migrates an installation of the old installer (the flat layout) into the new layout, in place: the
# install directory becomes the core root (PLAN.md 15, migration.md, m7-migration.md). Internal, not
# a user command. The old installer's stage one (<install dir>/update.sh, cron or by hand) downloads
# the newest release to /tmp/mgw-update, extracts it and runs its assets/scripts/update.sh
# -path=<install dir>, which hands over to this script:
#
#   migration.sh [-a] -path=<install dir>            from the extracted release in /tmp/mgw-update
#   migration.sh -copied [-a] -path=<install dir>    from <install dir>/vX_Y_Z_tmp, internal
#
# The old stage one has no lock and deletes /tmp/mgw-update when it starts, so the first run only
# checks, takes the new lock, records the migration and copies the release into vX_Y_Z_tmp; then it
# runs again from that copy (-copied) and never reads /tmp/mgw-update again (m7-migration.md,
# finding 4).
#
# All migration logic is here and in lib/migration.sh (migration.md decision 3), so the migration can
# be removed again without touching the rest.
#
# Exit codes: 0 migrated, or nothing to do (the lock is held, the retry limit is reached); 1 failed.

# the libraries' variables are used across files, which shellcheck can't follow
# shellcheck disable=SC2034,SC2154

auto=false
copied=false
old_path=""
for arg in "$@"
do
  case "$arg" in
    -a)
      auto=true
      ;;
    -copied)
      copied=true
      ;;
    -path=*)
      old_path="${arg#-path=}"
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

script_dir="$(dirname "$(readlink -f "$0")")"
for migration_lib in file settings state lock host semver render reconcile net docker objects core version setup update migration
do
  # shellcheck disable=SC1090
  . "$script_dir/lib/$migration_lib.sh" || exit 1
done

if [ "$old_path" = "" ] || ! core_root="$(cd "$old_path" 2> /dev/null && pwd -P)"
then
  echo "no installation found at '$old_path'" >&2
  exit 1
fi
if ! [ -e "$core_root/.settings" ] || [ -e "$core_root/current" ]
then
  echo "'$core_root' isn't an installation of the old installer" >&2
  exit 1
fi
assets_dir="$(cd "$script_dir/.." && pwd -P)"
new_version="$(cat "$assets_dir/version" 2> /dev/null)"
# a git clone has no assets/version, the release build writes it
[ "$new_version" != "" ] || new_version="dev-$(date +%s)"
new_folder="$(versionFolder "$new_version")" || exit 1
record="$core_root/state/update"
started="$(stateNow)"
from_version="$(migrationVersion "$core_root" 2> /dev/null)"

if ! settingsLoad "$assets_dir/settings.defaults" ""
then
  exit 1
fi

say() {
  printf '%s\n' "$*"
}

# ends a run that changed nothing in the installation: the reason $1 goes to stderr and into the old
# .update_status
refuse() {
  say "not migrating: $1" >&2
  migrationOldStatus "$core_root" failed "migration to $new_version: $1" "$from_version" "$new_version" "$started"
  exit 1
}

# B: a failure while preparing, the old core untouched (migration.md, interruptions). The new
# containers and version folder and state/settings go, the images stay (G1); the record says failed,
# not counting towards the retry limit, and so does the old .update_status. Releases the lock.
migrationFailB() {
  trap - INT TERM HUP
  say "the migration failed while preparing: $1" >&2
  objectsRemove "$core_root" "project:$(migrationOld core_name)_$new_folder" 2> /dev/null ||
    recordWarn upd "could not remove the containers of $new_folder"
  updateRecordFailure false "$1"
  for migration_folder in "${new_folder}_tmp" "$new_folder"
  do
    versionRemoveLeftover "$core_root" "$migration_folder" > /dev/null 2>&1 ||
      say "warning: could not remove $core_root/$migration_folder" >&2
  done
  rm -f "$core_root/state/settings"
  migrationOldStatus "$core_root" failed "migration to $new_version: $1" "$from_version" "$new_version" "$upd_started"
  say "the old installation is unchanged and keeps running as before" >&2
  lockRelease 2> /dev/null
  exit 1
}

if [ "$copied" != "true" ]
then
  # --- the run from /tmp/mgw-update (m7-migration.md, finding 4, steps 3 to 6) ---

  # 3. the checks, reading only
  say "migrating the installation in $core_root to $new_version ..."
  [ "$from_version" != "" ] || refuse "cannot read $core_root/.version"
  if ! migration_why="$(migrationVersionOk "$from_version")"
  then
    refuse "$migration_why; $(migrationTooOldHelp "$core_root")"
  fi
  migrationReadOld "$core_root" || refuse "cannot read $core_root/.settings"
  if ! migration_problems="$(migrationCheck "$core_root")"
  then
    say "the settings in $core_root/.settings don't fit the new layout:" >&2
    printf '%s\n' "$migration_problems" | sed 's/^/  /' >&2
    refuse "the settings don't fit the new layout: $(printf '%s\n' "$migration_problems" | head -n 1)"
  fi

  # 4. the first changes: state/, the lock, the record, the copy
  mkdir -p "$core_root/state" || refuse "cannot create $core_root/state"
  lockAcquire "$core_root/state/lock" migration
  case $? in
    0)
      ;;
    2)
      say "another update or migration of $core_root is running; it is responsible"
      exit 0
      ;;
    *)
      refuse "cannot take the lock $core_root/state/lock"
  esac
  recordClear upd "$state_update_fields" warning
  if recordLoad "$record" upd warning 2> /dev/null && [ "$upd_result" = "running" ]
  then
    lockRelease
    refuse "an interrupted migration needs recovering first, which this version can't do yet"
  fi
  limit="$(settingsGet update_retry_limit)"
  if [ "$auto" = "true" ] && attemptsLimitReached "$core_root/state/attempts" "$new_folder" "${limit:-3}"
  then
    say "the migration to $new_version failed $limit times, automatic runs skip it; run $core_root/update.sh without -a to try again"
    lockRelease
    exit 0
  fi
  if [ "$auto" != "true" ]
  then
    attemptsReset "$core_root/state/attempts" "$new_folder" > /dev/null 2>&1
  fi
  was_running=false
  migrationWasRunning "$core_root" && was_running=true

  recordClear upd "$state_update_fields" warning
  updateSet format "$state_format"
  updateSet writer "$new_folder"
  updateSet kind migration
  updateSet result running
  updateSet phase preparing
  updateSet started "$started"
  updateSet from_version "$from_version"
  updateSet to_version "$new_version"
  updateSet new_folder "$new_folder"
  updateSet was_running "$was_running"
  updateSet old_project "$(migrationOld stack_name)"
  updateSet step "copying $new_version into ${new_folder}_tmp"
  if ! updateRecordWrite "$record"
  then
    lockRelease
    refuse "cannot write $record"
  fi
  trap 'migrationFailB "interrupted"' INT TERM HUP
  testKill copying
  versionCreate "$core_root" "$assets_dir" "$new_version" || migrationFailB "copying $new_version into ${new_folder}_tmp"

  # 5. the copy must be the release: a second old stage one may have deleted or replaced
  # /tmp/mgw-update while it was copied
  case "$new_version" in
    dev-*)
      say "warning: $new_version is a dev version without checksums, the copy is unchecked" >&2
      ;;
    *)
      if ! testFail checksums || ! [ -f "$core_root/${new_folder}_tmp/assets/checksums" ] ||
        ! (cd "$core_root/${new_folder}_tmp/assets" && sha256sum -c --quiet checksums > /dev/null 2>&1)
      then
        migrationFailB "the copy of $new_version doesn't match its checksums; the release in $assets_dir changed while it was copied"
      fi
  esac
  testKill copied

  # 6. on from the copy; exec keeps descriptor 9 and MGW_LOCK_HELD (lockInherited)
  trap - INT TERM HUP
  exec "$core_root/${new_folder}_tmp/assets/scripts/migration.sh" -copied "$@"
fi

# --- the run from <install dir>/vX_Y_Z_tmp (-copied) ---

if [ "$script_dir" != "$core_root/${new_folder}_tmp/assets/scripts" ]
then
  echo "-copied is internal: migration.sh runs that way only from $core_root/${new_folder}_tmp" >&2
  exit 1
fi
if ! lockInherited "$core_root/state/lock" migration
then
  echo "-copied is internal: the lock must be inherited from the run that copied the release" >&2
  exit 1
fi
recordClear upd "$state_update_fields" warning
if ! recordLoad "$record" upd warning || [ "$upd_kind" != "migration" ] || [ "$upd_result" != "running" ] || [ "$upd_writer" != "$new_folder" ]
then
  echo "the migration record $record is missing or isn't this migration's" >&2
  lockRelease
  exit 1
fi
from_version="$upd_from_version"
migrationReadOld "$core_root" || migrationFailB "reading $core_root/.settings"
trap 'migrationFailB "interrupted"' INT TERM HUP

# the migration itself (migration.md steps 2 to 14) follows in the next commit
migrationFailB "the migration in place isn't implemented yet"
