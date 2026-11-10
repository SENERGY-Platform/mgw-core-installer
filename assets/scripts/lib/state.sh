#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# State files (PLAN.md 9, 10a). The records state/update, state/check and state/install are key=value
# files like the settings: the key is everything before the first "=", the value everything after it.
# Some keys repeat (warning=, created=) and are read as a list.
#
# Reading is tolerant: any valid key is read, unknown ones are simply not looked at by the caller,
# missing ones stay empty. A record is held in variables named <prefix>_<key>; a repeated key's
# variable holds its values separated by line breaks.
#
# Writing: the writer owns the whole record and writes it completely each time, through a temp file
# and a rename, readable by everyone (records hold no secrets). It never keeps keys it didn't set: a version taking over another version's record
# saves the old one unparsed (recordSavePrevious) and starts a fresh one.
#
# Needs lib/file.sh.

# The record variables are set and read through eval, and the constants are used by the scripts
# sourcing this file, which shellcheck can't see.
# shellcheck disable=SC2034,SC2154

state_format=1

# the fields of each record in the order they are written; the stable fields (PLAN.md 9) first
state_update_fields="format writer kind result phase started finished from_version to_version old_folder new_folder was_running rolled_back interrupted recovery_failed old_project step warnings_omitted"
state_check_fields="format check_time check_result check_version check_step warnings_omitted"
state_install_fields="format writer result mode started finished"

# a record file larger than this is refused, as the core-manager does
state_max_size=65536
# warnings per record and characters per warning (PLAN.md 9)
state_max_warnings=20
state_max_warning_len=200
# characters per value, so a step built from a command's output can't bloat the record
state_max_value_len=1000

state_cr="$(printf '\r')"
state_nl="
"

stateValidName() {
  case "$1" in
    ""|[!a-z]*|*[!a-z0-9_]*)
      return 1
  esac
}

# prints the current time in UTC, e.g. 2026-11-09T03:00:00Z
stateNow() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# prints $1 as a single line of at most $2 characters: line breaks become spaces
stateOneLine() {
  printf '%s' "$1" | tr '\r\n' '  ' | cut -c "1-$2"
}

# clears the variables of the record $1 for the fields $2 and the repeated keys $3
recordClear() {
  for record_clear_key in ${2} ${3}
  do
    unset "$1_$record_clear_key"
  done
}

# reads the record file $1 into variables with the prefix $2. $3 names the keys that repeat (e.g.
# "warning"). Returns 1 if the file doesn't exist, 2 if it can't be read or is larger than
# state_max_size. Variables of keys not in the file are left as they are; clear them first.
recordLoad() {
  if ! stateValidName "$2"
  then
    echo "invalid record prefix '$2'" >&2
    return 2
  fi
  if ! [ -e "$1" ]
  then
    return 1
  fi
  if ! [ -r "$1" ] || ! record_load_size="$(wc -c < "$1")"
  then
    echo "cannot read '$1'" >&2
    return 2
  fi
  if [ "$record_load_size" -gt "$state_max_size" ]
  then
    echo "'$1' is larger than $state_max_size bytes, not read" >&2
    return 2
  fi
  for record_load_key in ${3}
  do
    unset "$2_$record_load_key"
  done
  while IFS= read -r record_load_line || [ -n "$record_load_line" ]
  do
    record_load_line="${record_load_line%"$state_cr"}"
    case "$record_load_line" in
      *=*)
        ;;
      *)
        continue
    esac
    record_load_key="${record_load_line%%=*}"
    if ! stateValidName "$record_load_key"
    then
      continue
    fi
    record_load_value="${record_load_line#*=}"
    record_load_repeated=false
    for record_load_rkey in ${3}
    do
      if [ "$record_load_rkey" = "$record_load_key" ]
      then
        record_load_repeated=true
      fi
    done
    if [ "$record_load_repeated" = "true" ]
    then
      eval "record_load_list=\${$2_$record_load_key}"
          if [ "$record_load_list" = "" ]
      then
        eval "$2_$record_load_key=\$record_load_value"
      else
        eval "$2_$record_load_key=\"\$record_load_list\$state_nl\$record_load_value\""
      fi
    else
      eval "$2_$record_load_key=\$record_load_value"
    fi
  done < "$1"
}

# sets the field $2 of the record $1 to $3, as one line of at most state_max_value_len characters
recordSet() {
  if ! stateValidName "$1" || ! stateValidName "$2"
  then
    echo "invalid record field '$1_$2'" >&2
    return 1
  fi
  record_set_value="$(stateOneLine "$3" "$state_max_value_len")"
  eval "$1_$2=\$record_set_value"
}

# prints the field $2 of the record $1
recordGet() {
  if ! stateValidName "$1" || ! stateValidName "$2"
  then
    echo "invalid record field '$1_$2'" >&2
    return 1
  fi
  eval "printf '%s\n' \"\${$1_$2}\""
}

# appends $3 to the repeated key $2 of the record $1, as one line of at most $4 characters
# (state_max_value_len by default)
recordAppend() {
  if ! stateValidName "$1" || ! stateValidName "$2"
  then
    echo "invalid record field '$1_$2'" >&2
    return 1
  fi
  record_append_value="$(stateOneLine "$3" "${4:-$state_max_value_len}")"
  eval "record_append_list=\${$1_$2}"
  if [ "$record_append_list" = "" ]
  then
    eval "$1_$2=\$record_append_value"
  else
    eval "$1_$2=\"\$record_append_list\$state_nl\$record_append_value\""
  fi
}

# adds the warning $2 to the record $1: at most state_max_warnings, each at most
# state_max_warning_len characters. Further warnings are only counted, in warnings_omitted.
recordWarn() {
  eval "record_warn_list=\${$1_warning}"
  record_warn_count=0
  if [ "$record_warn_list" != "" ]
  then
    record_warn_count="$(printf '%s\n' "$record_warn_list" | wc -l)"
  fi
  if [ "$record_warn_count" -ge "$state_max_warnings" ]
  then
    eval "record_warn_omitted=\${$1_warnings_omitted:-0}"
      eval "$1_warnings_omitted=$((record_warn_omitted + 1))"
    return 0
  fi
  recordAppend "$1" warning "$2" "$state_max_warning_len"
}

# writes the record $2 to the file $1: the fields $3 in this order (empty ones as "key="), then each
# value of the repeated keys $4
recordWrite() {
  if ! stateValidName "$2"
  then
    echo "invalid record prefix '$2'" >&2
    return 1
  fi
  {
    for record_write_key in ${3}
    do
      eval "printf '%s=%s\n' \"\$record_write_key\" \"\${$2_$record_write_key}\""
    done
    for record_write_key in ${4}
    do
      eval "record_write_list=\${$2_$record_write_key}"
          if [ "$record_write_list" = "" ]
      then
        continue
      fi
      printf '%s\n' "$record_write_list" | while IFS= read -r record_write_value
      do
        printf '%s=%s\n' "$record_write_key" "$record_write_value"
      done
    done
  } | fileWriteAtomic "$1" 644
}

# keeps the record file $1 unparsed as $2 (e.g. state/update.previous) before a version that didn't
# write it starts a fresh one. Nothing to do if $1 doesn't exist.
recordSavePrevious() {
  if ! [ -e "$1" ]
  then
    return 0
  fi
  fileWriteAtomic "$2" < "$1"
}

# state/attempts: the failure count for the retry limit (PLAN.md 9). Prints the number of failures
# recorded in the file $1 for the version folder $2, 0 if the file is missing, unreadable or about
# another version.
attemptsFailures() {
  recordClear attempts "version failures"
  if ! recordLoad "$1" attempts "" 2> /dev/null || [ "$attempts_version" != "$2" ]
  then
    echo 0
    return 0
  fi
  case "$attempts_failures" in
    ""|*[!0-9]*)
      echo 0
      ;;
    *)
      echo "$attempts_failures"
  esac
}

# counts one more failure of the version folder $2 in the file $1; a failure of another version
# than the one recorded starts again at 1
attemptsAddFailure() {
  attempts_failures="$(($(attemptsFailures "$1" "$2") + 1))"
  attempts_version="$2"
  recordWrite "$1" attempts "version failures" ""
}

# resets the count after a success or a manual run
attemptsReset() {
  attempts_version="$2"
  attempts_failures=0
  recordWrite "$1" attempts "version failures" ""
}

# returns 0 if the version folder $2 has failed at least $3 times according to the file $1
attemptsLimitReached() {
  [ "$(attemptsFailures "$1" "$2")" -ge "$3" ]
}

# state/images: one image per line, every core image the install or an update pulled (PLAN.md 9, 11)

# adds the image $2 to the list $1, unless it is listed already
imagesAdd() {
  if [ -e "$1" ] && grep -qxF -- "$2" "$1"
  then
    return 0
  fi
  {
    if [ -e "$1" ]
    then
      grep -v '^$' "$1"
    fi
    printf '%s\n' "$2"
  } | fileWriteAtomic "$1" 644
}

# removes the image $2 from the list $1
imagesRemove() {
  if ! [ -e "$1" ] || ! grep -qxF -- "$2" "$1"
  then
    return 0
  fi
  grep -vxF -- "$2" "$1" | grep -v '^$' | fileWriteAtomic "$1" 644
}

# prints the images of the list $1, one per line
imagesList() {
  if [ -e "$1" ]
  then
    grep -v '^$' "$1"
  fi
}

# The test hook for failure injection (implementation.md, decision 5): returns 1 and says so if the
# environment variable MGW_TEST_FAIL_AT names the step $1 (several steps separated by spaces), so a VM
# test can make that step fail as if its command had failed. Only honoured when set explicitly; nothing
# in the release sets it.
testFail() {
  case " ${MGW_TEST_FAIL_AT:-} " in
    *" $1 "*)
      echo "test: failing at $1" >&2
      return 1
  esac
  return 0
}

# The test hook for interruptions: kills this process with SIGKILL if MGW_TEST_KILL_AT names the step
# $1, so a VM test can interrupt a run exactly there, without any of its own handling running (like a
# power loss). Only honoured when set explicitly; nothing in the release sets it.
testKill() {
  case " ${MGW_TEST_KILL_AT:-} " in
    *" $1 "*)
      echo "test: killed at $1" >&2
      kill -KILL $$
  esac
}
