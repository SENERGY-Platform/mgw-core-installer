#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# The recovery (PLAN.md 14): resolves an unfinished install or an interrupted update. Internal, not a
# user command; run by
#   - the recovery unit at boot: recover.sh -boot (through current)
#   - update.sh before it checks for a release, under its lock (G5)
#   - restore.sh, which tries the recovery first (10b)
#   - itself: the hand-over to the version that wrote the update record
#
#   recover.sh [-boot] [-by=<who>]
#
# -boot: no units are started or stopped (they start by themselves right after the recovery unit;
# starting them from it would deadlock). -by names the caller in the record's warning.
#
# - The lock tells whether a writer is alive. If someone else holds it, that holder is alive and
#   responsible; nothing to do (m2-assets-lib.md, finding 11). An inherited lock (update.sh, the
#   hand-over) stays with the caller.
# - An install that didn't record success was killed: it is removed with its own list, nothing may
#   start (exit 1).
# - An update record "running" while the lock is held here: the update was interrupted. The version
#   that wrote the record recovers it, by the phase it reached; if that version's folder is missing
#   or damaged, nobody can, and the core is left for restore.sh (G9).
#
# Exit codes: 0 nothing (more) to recover, 1 failed, G9, or an unfinished install was removed.

# the libraries' variables are used across files, which shellcheck can't follow
# shellcheck disable=SC2034,SC2154

boot=false
by=""
for arg in "$@"
do
  case "$arg" in
    -boot)
      boot=true
      by="the boot recovery"
      ;;
    -by=*)
      by="${arg#-by=}"
      ;;
  esac
done
[ "$by" != "" ] || by="recover.sh"

# the core root and this version's folder: this script is
# <core root>/<version folder>/assets/scripts/recover.sh, usually reached through current
if ! script_dir="$(cd "${0%/*}" && pwd -P)" || ! core_root="$(cd "$script_dir/../../.." && pwd -P)"
then
  exit 1
fi
own_folder="$(basename "$(dirname "$(dirname "$script_dir")")")"
own_folder="${own_folder%_tmp}"
for recover_lib in file settings state lock host render reconcile net docker objects core version update
do
  # shellcheck disable=SC1090
  . "$script_dir/lib/$recover_lib.sh" || exit 1
done

recover_inherited=false
if lockInherited "$core_root/state/lock" recover
then
  recover_inherited=true
else
  lockAcquire "$core_root/state/lock" recover
  case $? in
    0)
      ;;
    2)
      echo "the lock is held, its holder is responsible; nothing to recover"
      exit 0
      ;;
    *)
      exit 1
  esac
fi

# releases the lock unless it belongs to the caller
recoverRelease() {
  if [ "$recover_inherited" != "true" ]
  then
    lockRelease 2> /dev/null
  fi
}

recoverExit() {
  recoverRelease
  exit "$1"
}

# --- an unfinished install (10a) ---

recordClear recover_inst "result" ""
if recordLoad "$core_root/state/install" recover_inst "" && [ "$recover_inst_result" != "success" ]
then
  echo "unfinished install found (result '$recover_inst_result'), removing it ..." >&2
  if [ -r "$core_root/current/assets/settings.defaults" ]
  then
    settingsLoad "$core_root/current/assets/settings.defaults" "$core_root/state/settings" 2> /dev/null
  fi
  if installCleanup "$core_root" "$core_root/state/install"
  then
    echo "the unfinished install was removed; run setup.sh again" >&2
  else
    echo "removing the unfinished install left something behind, listed in $core_root/state/install" >&2
  fi
  recoverExit 1
fi

# --- an interrupted update (14) ---

record="$core_root/state/update"
recordClear upd "$state_update_fields" warning
recordLoad "$record" upd warning
case $? in
  0)
    ;;
  1)
    recoverExit 0
    ;;
  *)
    upd_result=unreadable
esac

if [ "$upd_recovery_failed" = "true" ]
then
  echo "the recovery of an interrupted update failed before; repair the core with $core_root/current/restore.sh" >&2
  recoverExit 1
fi
if [ "$upd_result" != "running" ] && [ "$upd_result" != "unreadable" ]
then
  recoverExit 0
fi

# G9 without the writer: nobody knows exactly what the missing version changed. The record is taken
# over (9): the old content kept unparsed as state/update.previous, a fresh record with this version
# as the writer, the stable fields, result failed, interrupted, recovery_failed. Nothing is repaired.
takeOver() {
  echo "$1; the interrupted update can't be recovered, repair the core with $core_root/current/restore.sh" >&2
  recordSavePrevious "$record" "$record.previous" || echo "cannot keep $record as $record.previous" >&2
  updateSet format "$state_format"
  updateSet writer "$own_folder"
  updateSet result failed
  updateSet interrupted true
  updateSet recovery_failed true
  updateSet rolled_back false
  updateSet finished "$(stateNow)"
  upd_warning=""
  recordWarn upd "$1"
  recordWarn upd "found by $by"
  updateRecordWrite "$record" || echo "cannot write $record" >&2
  recoverExit 1
}

if [ "$upd_result" = "unreadable" ]
then
  recordClear upd "$state_update_fields" warning
  takeOver "the update record state/update can't be read"
fi

# hands over to the writer (14): the version that wrote the record knows what it changed
if [ "$upd_writer" != "$own_folder" ]
then
  writer_dir=""
  for writer_candidate in "$core_root/$upd_writer" "$core_root/${upd_writer}_tmp"
  do
    if [ "$upd_writer" != "" ] && [ -f "$writer_candidate/assets/scripts/recover.sh" ]
    then
      writer_dir="$writer_candidate"
      break
    fi
  done
  if [ "$writer_dir" = "" ]
  then
    takeOver "the version folder ${upd_writer:-?} of the interrupted update is missing"
  fi
  # the checksums detect a damaged folder (e.g. a truncated file after a power loss); release
  # versions must have them, dev versions never do (m5-update.md, finding 9)
  case "$upd_writer" in
    dev-*)
      echo "warning: $upd_writer is a dev version without checksums, handing over unchecked" >&2
      ;;
    *)
      if ! [ -f "$writer_dir/assets/checksums" ] || ! (cd "$writer_dir/assets" && sha256sum -c --quiet checksums > /dev/null 2>&1)
      then
        takeOver "the version folder $upd_writer of the interrupted update is damaged (checksums)"
      fi
  esac
  echo "handing the recovery over to $upd_writer ..."
  if [ "$upd_kind" = "migration" ]
  then
    if [ -x "$writer_dir/assets/scripts/migration.sh" ]
    then
      exec "$writer_dir/assets/scripts/migration.sh" -recover "$@"
    fi
    takeOver "the interrupted migration's version folder $upd_writer has no migration.sh"
  fi
  # exec keeps the lock's descriptor and MGW_LOCK_HELD
  exec "$writer_dir/assets/scripts/recover.sh" "$@"
fi

if [ "$upd_kind" = "migration" ]
then
  if [ -x "$script_dir/migration.sh" ]
  then
    exec "$script_dir/migration.sh" -recover "$@"
  fi
  takeOver "this version ($own_folder) can't recover an interrupted migration"
fi

# this version wrote the record: recover by the phase it reached
core_name=""
if [ -r "$core_root/current/assets/settings.defaults" ]
then
  settingsLoad "$core_root/current/assets/settings.defaults" "$core_root/state/settings" 2> /dev/null
else
  settingsLoad "$script_dir/../settings.defaults" "$core_root/state/settings" 2> /dev/null
fi
core_name="$(settingsGet core_name)"
old_folder="$upd_old_folder"
new_folder="$upd_new_folder"
was_running="$upd_was_running"
[ "$boot" = "true" ] && update_start_allowed=false
if [ "$old_folder" = "" ] || [ "$new_folder" = "" ] || [ "$core_name" = "" ]
then
  takeOver "the update record lacks the version folders or the core name"
fi
updateSet interrupted true
recordWarn upd "interrupted, recovered by $by"
interrupted_step="${upd_step:-interrupted}"
echo "recovering the update from $upd_from_version to $upd_to_version, interrupted in phase ${upd_phase:-?} ..."
case "$upd_phase" in
  preparing)
    updateHandleB "$interrupted_step"
    ;;
  switching)
    updateHandleC "$interrupted_step"
    ;;
  *)
    # starting, or a phase this version doesn't know: past the point of no return (a kill right after
    # the record can't tell whether a binary started; rolling back after a migration may have run is
    # the one thing that must not happen)
    updateHandleD "$interrupted_step"
esac
echo "the interrupted update was recovered"
recoverExit 0
