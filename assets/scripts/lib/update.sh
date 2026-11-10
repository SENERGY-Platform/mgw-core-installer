#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# The parts of update.sh that don't need docker or the network (PLAN.md 10): choosing the release to
# update to, and stage one's record in state/check.
#
# Needs lib/semver.sh, lib/state.sh and jq.

# state_* come from lib/state.sh, update_repo is used by update.sh
# shellcheck disable=SC2034,SC2154

update_repo="SENERGY-Platform/mgw-core-installer"

# prints the tag of the newest release in the GitHub release list $1 (JSON) that is newer than the
# version $2, nothing if there is none. Drafts never count, pre-releases only if $3 is true; tags
# that aren't release versions are ignored.
updatePickRelease() {
  update_best=""
  for update_tag in $(jq -r --argjson beta "$3" '.[] | select(.draft != true) | select($beta or .prerelease != true) | .tag_name' "$1")
  do
    semverValid "$update_tag" || continue
    # a pre-release tag counts as one, also if the release isn't marked as such
    if semverIsPre "$update_tag" && [ "$3" != "true" ]
    then
      continue
    fi
    if [ "$update_best" = "" ] || semverLess "$update_best" "$update_tag"
    then
      update_best="$update_tag"
    fi
  done
  if [ "$update_best" != "" ] && semverLess "$2" "$update_best"
  then
    echo "$update_best"
  fi
}

# writes stage one's record to the file $1 (state/check): result $2 (up_to_date, update_available,
# skipped, failed), the version found $3, the step $4 (what failed or why it was skipped) and the
# warnings after $4. Returns 1 if it can't be written (S2: then stage one doesn't go on).
updateCheckRecord() {
  update_check_file="$1"
  recordClear chk "$state_check_fields" warning
  recordSet chk format "$state_format"
  recordSet chk check_time "$(stateNow)"
  recordSet chk check_result "$2"
  recordSet chk check_version "$3"
  recordSet chk check_step "$4"
  shift 4
  for update_warning in "$@"
  do
    recordWarn chk "$update_warning"
  done
  recordWrite "$update_check_file" chk "$state_check_fields" warning
}

# --- stage two's record, state/update (PLAN.md 9, 14) ---

# writes the record held in the upd_ variables to the file $1. The phase records are mandatory (S2):
# the caller decides what a failed write means.
updateRecordWrite() {
  recordWrite "$1" upd "$state_update_fields" warning
}

# sets the field $1 of the record to $2
updateSet() {
  recordSet upd "$1" "$2"
}

# --- the cleanup after a successful update (PLAN.md 11) ---

# removes everything of the core root $1 that doesn't belong to the current version: other version
# folders (leftover vX_Y_Z_tmp included), core containers of other compose projects, and recorded core
# images the current version doesn't use. Never forced: an image still in use stays listed and is
# tried again next time. Module images and anything not belonging to the core are never touched.
# Prints a warning per leftover and returns 1 if something is left.
updateCleanup() {
  update_cl_rc=0
  update_cl_current="$(readlink "$1/current")"
  update_cl_project="$(settingsGet core_name)_$update_cl_current"
  # containers first: the folders' options identify the images
  for update_cl_ctr in $(docker ps -a --filter "label=mgw_cid=$(settingsGet core_id)" --filter "label=core_srv=true" \
    --format '{{.ID}}:{{.Label "com.docker.compose.project"}}')
  do
    if [ "${update_cl_ctr#*:}" != "$update_cl_project" ]
    then
      if ! docker rm -f -v "${update_cl_ctr%%:*}" > /dev/null 2>&1
      then
        echo "cleanup: container ${update_cl_ctr%%:*} not removed"
        update_cl_rc=1
      fi
    fi
  done
  # images: the current version's options list the images it uses
  # shellcheck disable=SC1091 # the current version's own static asset
  update_cl_used="$(. "$1/current/assets/options" > /dev/null 2>&1; for update_cl_i in $images; do echo "${update_cl_i#*=}"; done)"
  for update_cl_image in $(imagesList "$1/state/images")
  do
    if printf '%s\n' "$update_cl_used" | grep -qxF -- "$update_cl_image"
    then
      continue
    fi
    if ! docker image inspect "$update_cl_image" > /dev/null 2>&1 || docker image rm "$update_cl_image" > /dev/null 2>&1
    then
      imagesRemove "$1/state/images" "$update_cl_image"
    else
      echo "cleanup: image $update_cl_image still in use, not removed"
      update_cl_rc=1
    fi
  done
  for update_cl_dir in "$1"/v* "$1"/dev-*
  do
    if ! [ -d "$update_cl_dir" ] || [ -L "$update_cl_dir" ] || [ "${update_cl_dir##*/}" = "$update_cl_current" ]
    then
      continue
    fi
    if ! objectsRemove "$1" "folder:${update_cl_dir##*/}" 2> /dev/null
    then
      echo "cleanup: $update_cl_dir not removed"
      update_cl_rc=1
    fi
  done
  return $update_cl_rc
}

# --- the handling per phase (PLAN.md 13), shared by stage two and the recovery (14) ---
#
# They work on: core_root, core_name, record (state/update), old_folder, new_folder, was_running, the
# record in the upd_ variables, and update_start_allowed (false at boot, see updateHandleC).

update_start_allowed=true

# records the final result of a failure: rolled_back $1, the step $2; counts it towards the retry
# limit if $3 is "count" (G8: only failures from the stop on). A failed write is only logged: this
# runs during or after the handling (S2).
updateRecordFailure() {
  updateSet result failed
  updateSet rolled_back "$1"
  updateSet step "$2"
  updateSet finished "$(stateNow)"
  if [ "$3" = "count" ] && ! attemptsAddFailure "$core_root/state/attempts" "$new_folder"
  then
    recordWarn upd "could not count the failure in state/attempts"
  fi
  updateRecordWrite "$record" || echo "cannot write $record" >&2
}

# G9: the error handling itself failed. Nothing more is attempted; the core is left as it is and
# needs restore.sh. ctrl.sh refuses changing commands, the units don't start at boot.
updateHandlingFailed() {
  echo "the error handling failed at: $1" >&2
  echo "nothing more is attempted; repair the core with $core_root/current/restore.sh" >&2
  updateSet recovery_failed true
  updateRecordFailure false "$2; the rollback failed at: $1" count
  exit 1
}

# B: the old core is untouched. Remove the new containers, keep the images (G1), record, then remove
# the new version folder (never the one current points to). Doesn't count towards G8.
updateHandleB() {
  objectsRemove "$core_root" "project:${core_name}_$new_folder" 2> /dev/null ||
    recordWarn upd "could not remove the containers of $new_folder"
  updateRecordFailure false "$1"
  for handle_folder in "${new_folder}_tmp" "$new_folder"
  do
    versionRemoveLeftover "$core_root" "$handle_folder" > /dev/null 2>&1 ||
      echo "warning: could not remove $core_root/$handle_folder" >&2
  done
}

# C: the rollback. The old containers were only stopped, the old folder never modified: pointing
# back is enough. Every step can be repeated (G6); a failing one is G9.
updateHandleC() {
  echo "rolling back to $old_folder ..." >&2
  testFail rollback || updateHandlingFailed "removing the containers of $new_folder" "$1"
  objectsRemove "$core_root" "project:${core_name}_$new_folder" 2> /dev/null ||
    updateHandlingFailed "removing the containers of $new_folder" "$1"
  settingsLoad "$core_root/$old_folder/assets/settings.defaults" "$core_root/state/settings" ||
    updateHandlingFailed "reading the settings of $old_folder" "$1"
  versionActivate "$core_root" "$old_folder" || updateHandlingFailed "activating $old_folder" "$1"
  # at boot the units start by themselves right after the recovery unit; starting them from it would
  # deadlock (m5-update.md, finding 2)
  if [ "$was_running" = "true" ] && [ "$update_start_allowed" = "true" ]
  then
    coreStart "$core_root" || updateHandlingFailed "starting $old_folder" "$1"
  fi
  updateRecordFailure true "$1" count
  for handle_folder in "${new_folder}_tmp" "$new_folder"
  do
    versionRemoveLeftover "$core_root" "$handle_folder" > /dev/null 2>&1 ||
      echo "warning: could not remove $core_root/$handle_folder" >&2
  done
}

# D: past the point of no return, no rollback (G3): data migrations may have run. The half-started
# new version is left as it is, the old version kept for investigation.
updateHandleD() {
  updateRecordFailure false "$1" count
}

