#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# Migrates an installation of the old installer (the flat layout) into the new layout, in place: the
# install directory becomes the core root (PLAN.md 15, migration.md, m7-migration.md). Internal, not
# a user command. The old installer's stage one (<install dir>/update.sh, cron or by hand) downloads
# the newest release to /tmp/mgw-update, extracts it and runs its assets/scripts/update.sh
# -path=<install dir>, which hands over to this script:
#
#   migration.sh [-a] -path=<install dir>            from the extracted release in /tmp/mgw-update
#   migration.sh -copied [-work=<dir>] [-a] -path=<install dir>
#                                                    from <install dir>/vX_Y_Z_tmp, internal; -work
#                                                    names the old stage one's work folder, removed
#                                                    after a success
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
old_work=""
for arg in "$@"
do
  case "$arg" in
    -a)
      auto=true
      ;;
    -copied)
      copied=true
      ;;
    -work=*)
      old_work="${arg#-work=}"
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

  # 6. on from the copy; exec keeps descriptor 9 and MGW_LOCK_HELD (lockInherited). The old stage
  # one extracted the release to <work folder>/extract; the copy removes that folder after a success
  trap - INT TERM HUP
  case "$assets_dir" in
    */extract/assets)
      set -- "-work=${assets_dir%/extract/assets}" "$@"
  esac
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
was_running="$upd_was_running"
core_name=""
# this script runs from vX_Y_Z_tmp, which is renamed to vX_Y_Z while it runs; nothing below keeps a
# path into it
new_dir="$core_root/$new_folder"
aside="$core_root/state/migration/etc"
pull_limit=0
ctr_limit=0
if [ "$auto" = "true" ]
then
  pull_limit="$docker_pull_limit"
  ctr_limit="$docker_ctr_limit"
fi

# records the step $1 (informational) and writes the record; returns 1 if it can't be written
step() {
  updateSet step "$1"
  say "$1 ..."
  updateRecordWrite "$record"
}

# a failure in the phase $1 (B, C, D) at the step $2; called by the signal trap
# shellcheck disable=SC2317
migrationFail() {
  case "$1" in
    B)
      migrationFailB "$2"
      ;;
    C)
      migrationRollback "$2"
      ;;
    D)
      migrationFailD "$2"
  esac
}

# G9 for the migration: the rollback itself failed at $1, for the failure $2. Nothing more is
# attempted. state/settings and the new version folder stay, so the new layout can be completed with
# restore.sh; the old files moved aside are in state/migration/etc.
migrationHandlingFailed() {
  say "the rollback failed at: $1" >&2
  say "nothing more is attempted; complete the new layout with $new_dir/restore.sh -path=$core_root" >&2
  updateSet recovery_failed true
  updateRecordFailure false "$2; the rollback failed at: $1" count
  migrationOldStatus "$core_root" failed "migration to $new_version: $2; the rollback failed at: $1" "$from_version" "$new_version" "$upd_started"
  lockRelease 2> /dev/null
  exit 1
}

# C: the old core was stopped; nothing of the old installation was changed but its files in /etc,
# which were moved aside. The rollback restores the old flat layout (migration.md, rollback) and
# starts the old core with its own ctrl.sh if it was running. Every step can be repeated; a failing
# one is G9.
migrationRollback() {
  trap - INT TERM HUP
  say "the migration failed: $1" >&2
  say "rolling back to the old installation ..." >&2
  testFail rollback || migrationHandlingFailed "removing the containers of $new_folder" "$1"
  objectsRemove "$core_root" "project:${core_name}_$new_folder" 2> /dev/null ||
    migrationHandlingFailed "removing the containers of $new_folder" "$1"
  objectsRemoveEtcLinks "$core_root" || migrationHandlingFailed "removing the links in /etc" "$1"
  objectsRemove "$core_root" "link:current" || migrationHandlingFailed "removing current" "$1"
  # the core-owned units this migration wrote; a mount unit with the old one's name comes back below
  for migration_unit in "$core_name-recover.service" "$(systemd-escape --path --suffix=mount "/mnt/$core_name/secrets")"
  do
    if [ -f "$host_systemd_path/$migration_unit" ] && ! grep -qxF "$host_systemd_path/$migration_unit" "$aside/moved" 2> /dev/null
    then
      systemctl disable "$migration_unit" > /dev/null 2>&1
      objectsRemove "$core_root" "file:$host_systemd_path/$migration_unit" || migrationHandlingFailed "removing $migration_unit" "$1"
    fi
  done
  migrationMoveBack "$aside" "$core_root" || migrationHandlingFailed "putting the old files in /etc back" "$1"
  if [ "$(migrationOld systemd)" = "true" ]
  then
    systemctl daemon-reload || migrationHandlingFailed "systemctl daemon-reload" "$1"
  fi
  if [ "$(migrationOld advertise)" = "true" ]
  then
    systemctl reload avahi-daemon 2> /dev/null || avahi-daemon --reload 2> /dev/null ||
      recordWarn upd "avahi reload failed"
  fi
  # without systemd the old ctrl.sh starts detached processes: they must not inherit the lock
  if [ "$was_running" = "true" ] && [ "$update_start_allowed" = "true" ]
  then
    say "starting the old core ..."
    (cd "$core_root" && ./ctrl.sh start) 9>&- || migrationHandlingFailed "starting the old core with $core_root/ctrl.sh" "$1"
  fi
  updateRecordFailure true "$1" count
  for migration_folder in "${new_folder}_tmp" "$new_folder"
  do
    versionRemoveLeftover "$core_root" "$migration_folder" > /dev/null 2>&1 ||
      say "warning: could not remove $core_root/$migration_folder" >&2
  done
  # what the migration added to state/; state/update, state/attempts, state/images and the lock stay
  for migration_name in state/settings state/target_state state/host-manager state/migration
  do
    objectsRemove "$core_root" "folder:$migration_name" || say "warning: could not remove $core_root/$migration_name" >&2
  done
  migrationOldStatus "$core_root" failed "migration to $new_version: $1 (rolled back)" "$from_version" "$new_version" "$upd_started"
  say "rolled back: the old installation is as before" >&2
  lockRelease 2> /dev/null
  exit 1
}

# D: past the point of no return, no rollback (G3): a host binary of the new version started, data
# migrations may have run. The new core is left as it is; the old files stay for investigation.
migrationFailD() {
  trap - INT TERM HUP
  say "the migration failed after the new core started: $1" >&2
  say "the new layout stays; see $core_root/current/ctrl.sh status, repair with $core_root/current/restore.sh" >&2
  updateRecordFailure false "$1" count
  lockRelease 2> /dev/null
  exit 1
}

update_phase=B
trap 'migrationFail "$update_phase" "interrupted"' INT TERM HUP
migrationReadOld "$core_root" || migrationFailB "reading $core_root/.settings"
core_name="$(migrationOld core_name)"

# --- B: preparation, the old core untouched (migration.md steps 2 to 5) ---

# 2. state/settings from the old .settings and container/.env
step "writing state/settings" || migrationFailB "writing $record"
migration_warnings="$core_root/state/.migration-warnings"
if ! migrationSettings "$core_root" 2> "$migration_warnings" | fileWriteAtomic "$core_root/state/settings" ||
  ! [ -s "$core_root/state/settings" ]
then
  migrationFailB "writing state/settings"
fi
while IFS= read -r migration_warning
do
  say "$migration_warning" >&2
  recordWarn upd "${migration_warning#warning: }"
done < "$migration_warnings"
rm -f "$migration_warnings"
for migration_folder in deployments log mounts/nginx mounts/kratos sockets state/host-manager
do
  mkdir -p "$core_root/$migration_folder" || migrationFailB "creating $migration_folder"
done
mkdir -p "$(migrationOld host_dir_repository_path)" || migrationFailB "creating the host dir repository"
testKill settings

# 4. the version, up to the created containers. state/images starts with the old version's images,
# so the cleanup after the success removes the ones the new version doesn't use (11)
for migration_image in $(migrationOldImages "$core_root")
do
  imagesAdd "$core_root/state/images" "$migration_image" || migrationFailB "writing state/images"
done
step "preparing $new_version" || migrationFailB "writing $record"
versionBuild "$core_root" "$new_version" "$pull_limit" "$ctr_limit" pin
build_rc=$?
[ $build_rc -eq 0 ] || migrationFailB "preparing $new_version (exit code $build_rc)"
testFail prepare || migrationFailB "preparing $new_version"

# 5. the host-manager's data, copied: the old files stay for a rollback
migrationCopyHostManager "$core_root" || migrationFailB "copying the host-manager's data"

# --- C: switching, the old core stopped (migration.md steps 6 to 10) ---

updateSet phase switching
step "switching to $new_version" || migrationFailB "recording the switch"
testKill switching
update_phase=C

# 7. stop the old core
testFail stop || migrationRollback "stopping the old core"
migrationStopOld "$core_root" || migrationRollback "stopping the old core"
testKill stopped

# 8. the old files in /etc aside
migrationMoveAside "$core_root" "$aside" || migrationRollback "moving the old files in /etc aside"
testKill moved

# 9. the core-owned units (6, 14): the mount unit replaces the old one and isn't restarted (the tmpfs
# stays mounted), the recovery unit is new
if [ "$(settingsGet autostart)" = "true" ]
then
  migration_mount_unit="$(systemd-escape --path --suffix=mount "/mnt/$core_name/secrets")"
  if ! fileWriteAtomic "$host_systemd_path/$migration_mount_unit" 644 < "$new_dir/config/systemd-units/core/secrets.mount" ||
    ! fileWriteAtomic "$host_systemd_path/$core_name-recover.service" 644 < "$new_dir/config/systemd-units/core/recover.service" ||
    ! systemctl daemon-reload
  then
    migrationRollback "writing the core-owned units"
  fi
  for migration_unit in "$migration_mount_unit" "$core_name-recover.service"
  do
    systemctl enable "$migration_unit" > /dev/null 2>&1 || migrationRollback "enabling $migration_unit"
  done
fi
testFail units || migrationRollback "writing the core-owned units"

# 10. current, the links in /etc
versionActivate "$core_root" "$new_folder" || migrationRollback "activating $new_folder"
[ "$version_warning" = "" ] || recordWarn upd "$version_warning"
testFail activate || migrationRollback "activating $new_folder"
testKill activated

# --- D: starting, the point of no return (migration.md step 11) ---

if [ "$was_running" = "true" ]
then
  updateSet phase starting
  step "starting $new_version" || migrationRollback "recording the start"
  testKill starting
  coreSetTarget "$core_root" running || recordWarn upd "could not write state/target_state"
  # S8: the point of no return is the first host binary starting; a start that fails before is
  # still rolled back
  start_mark="$(coreStartMark "$core_root")"
  update_phase=D
  if ! testFail start || ! coreStart "$core_root"
  then
    if coreStartedSince "$core_root" "$start_mark"
    then
      migrationFailD "starting $new_version"
    fi
    update_phase=C
    migrationRollback "starting $new_version (no host binary started)"
  fi
  testFail started || migrationFailD "starting $new_version"
else
  coreSetTarget "$core_root" stopped || recordWarn upd "could not write state/target_state"
fi

# --- E: success, then the cleanup (migration.md steps 12 to 14) ---

updateSet result success
updateSet phase "done"
updateSet finished "$(stateNow)"
if ! testFail success || ! step "cleaning up"
then
  # S2: past the point of no return a failed write is only logged; with a core that wasn't running
  # no binary started, the migration is still in C and is rolled back
  if [ "$was_running" = "true" ]
  then
    say "warning: cannot write $record" >&2
  else
    migrationRollback "recording the success"
  fi
fi
trap - INT TERM HUP
attemptsReset "$core_root/state/attempts" "$new_folder" > /dev/null 2>&1

# 13. the old installation by an explicit list, its containers first so their images can go; then
# what updateCleanup removes after every update (old images via state/images)
cleanup_out=""
if ! testFail cleanup
then
  cleanup_out="the cleanup failed (test)"
else
  objectsRemove "$core_root" "project:$(migrationOld stack_name)" 2> /dev/null ||
    cleanup_out="the old containers not removed"
  cleanup_out="$cleanup_out$state_nl$(migrationRemoveOld "$core_root")"
  cleanup_out="$cleanup_out$state_nl$(updateCleanup "$core_root")"
  # 14. the old stage one's work folder; nothing runs from it any more. Only its own name is removed
  # (/tmp/mgw-update; the VM tests give each test file a folder of its own, /tmp/mgw-update-<name>)
  case "$old_work" in
    /tmp/mgw-update|/tmp/mgw-update-*)
      objectsRemove "$core_root" "dir:$old_work" || cleanup_out="$cleanup_out$state_nl$old_work not removed"
  esac
fi
cleanup_out="$(printf '%s\n' "$cleanup_out" | sed '/^$/d')"
if [ "$cleanup_out" != "" ]
then
  while IFS= read -r cleanup_line
  do
    say "warning: $cleanup_line" >&2
    recordWarn upd "$cleanup_line"
  done <<CLEANUP
$cleanup_out
CLEANUP
  updateSet step "done, the cleanup left something behind"
else
  updateSet step "done"
fi
updateRecordWrite "$record" || say "warning: cannot write $record" >&2
lockRelease
say "migrated to $new_version: $core_root is the core root now; control the core with $core_root/current/ctrl.sh"
exit 0
