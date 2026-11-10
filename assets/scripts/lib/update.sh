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
