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
