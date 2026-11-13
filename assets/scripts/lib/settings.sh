#!/bin/sh

# Settings (PLAN.md 8). The effective settings are the version's assets/settings.defaults with
# state/settings on top. Both files are key=value, one per line: the key is everything before the
# first "=", the value everything after it, taken literally (no quotes, no comments after a value).
# Empty lines and lines starting with "#" are ignored, a repeated key keeps its last value. The files
# are parsed, never sourced: state/settings may have been written by another version.
#
# settings.defaults defines which keys this version knows. A key in state/settings that it doesn't
# know (written by a newer version, still there after a rollback) is ignored when reading and kept
# when writing.
#
# Needs lib/file.sh.

# the known keys in the order of settings.defaults, separated by spaces
settings_keys=""

settings_cr="$(printf '\r')"

# splits the line $1 into settings_line_key and settings_line_value, returns 1 for a line that holds
# no setting
settingsParseLine() {
  settings_line="${1%"$settings_cr"}"
  case "$settings_line" in
    *=*)
      ;;
    *)
      return 1
  esac
  settings_line_key="${settings_line%%=*}"
  if ! settingsValidKey "$settings_line_key"
  then
    return 1
  fi
  # shellcheck disable=SC2034 # read through eval in settingsLoad
  settings_line_value="${settings_line#*=}"
}

# returns 0 if $1 is a valid key: lowercase letters, digits and "_", starting with a letter
settingsValidKey() {
  case "$1" in
    ""|[!a-z]*|*[!a-z0-9_]*)
      return 1
  esac
}

settingsKnown() {
  for settings_known_key in ${settings_keys}
  do
    if [ "$settings_known_key" = "$1" ]
    then
      return 0
    fi
  done
  return 1
}

# loads the effective settings: the defaults file $1, then the overrides file $2 on top. $2 may be
# missing (before the install wrote it). Values are kept in the variables settings_v_<key>, the
# origin (default or set) in settings_o_<key>; use settingsGet and settingsIsSet.
settingsLoad() {
  if ! [ -r "$1" ]
  then
    echo "cannot read settings defaults '$1'" >&2
    return 1
  fi
  for settings_load_key in ${settings_keys}
  do
    unset "settings_v_$settings_load_key" "settings_o_$settings_load_key"
  done
  settings_keys=""
  while IFS= read -r settings_load_line || [ -n "$settings_load_line" ]
  do
    if ! settingsParseLine "$settings_load_line"
    then
      continue
    fi
    if ! settingsKnown "$settings_line_key"
    then
      settings_keys="${settings_keys:+$settings_keys }$settings_line_key"
    fi
    eval "settings_v_$settings_line_key=\$settings_line_value"
    eval "settings_o_$settings_line_key=default"
  done < "$1"
  if ! [ -e "$2" ]
  then
    return 0
  fi
  if ! [ -r "$2" ]
  then
    echo "cannot read settings '$2'" >&2
    return 1
  fi
  while IFS= read -r settings_load_line || [ -n "$settings_load_line" ]
  do
    if ! settingsParseLine "$settings_load_line" || ! settingsKnown "$settings_line_key"
    then
      continue
    fi
    eval "settings_v_$settings_line_key=\$settings_line_value"
    eval "settings_o_$settings_line_key=set"
  done < "$2"
}

# prints the comment at the top of a core's state/settings, written by the install and the migration
settingsHeader() {
  echo "# The settings set for this core, on top of the version's defaults (assets/settings.defaults)."
  echo "# Change them with ctrl.sh settings set <key> <value>, not by editing this file: ctrl.sh checks"
  echo "# a value and applies it. The core's identity, credentials and subnets are fixed."
}

# prints the effective value of the known key $1, returns 1 for an unknown key
settingsGet() {
  if ! settingsKnown "$1"
  then
    echo "unknown setting '$1'" >&2
    return 1
  fi
  eval "printf '%s\n' \"\$settings_v_$1\""
}

# returns 0 if the known key $1 comes from the overrides file, 1 if it is a default or unknown
settingsIsSet() {
  if ! settingsKnown "$1"
  then
    return 1
  fi
  eval "[ \"\$settings_o_$1\" = set ]"
}

# prints the overrides file $1 without the lines of key $2, for rewriting it
settingsWithout() {
  if ! [ -e "$1" ]
  then
    return 0
  fi
  while IFS= read -r settings_wo_line || [ -n "$settings_wo_line" ]
  do
    if settingsParseLine "$settings_wo_line" && [ "$settings_line_key" = "$2" ]
    then
      continue
    fi
    printf '%s\n' "$settings_wo_line"
  done < "$1"
}

settingsCheckWrite() {
  if ! settingsValidKey "$1"
  then
    echo "invalid setting key '$1'" >&2
    return 1
  fi
  case "$2" in
    *"
"*)
      echo "invalid value for setting '$1': contains a line break" >&2
      return 1
  esac
}

# sets the key $2 to the value $3 in the overrides file $1, replacing an existing value. Everything
# else in the file stays, including keys this version doesn't know. Doesn't change the loaded
# settings; load again to see the change.
settingsSet() {
  if ! settingsCheckWrite "$2" "$3"
  then
    return 1
  fi
  if ! settings_set_rest="$(settingsWithout "$1" "$2")"
  then
    return 1
  fi
  {
    if [ "$settings_set_rest" != "" ]
    then
      printf '%s\n' "$settings_set_rest"
    fi
    printf '%s=%s\n' "$2" "$3"
  } | fileWriteAtomic "$1"
}

# sets the key $2 to the value $3 in the overrides file $1 only if the file doesn't have the key yet.
# For an update that pins a new setting (PLAN.md 8): it may add a key, never change one.
settingsAdd() {
  if ! settingsCheckWrite "$2" "$3"
  then
    return 1
  fi
  if [ -e "$1" ]
  then
    while IFS= read -r settings_add_line || [ -n "$settings_add_line" ]
    do
      if settingsParseLine "$settings_add_line" && [ "$settings_line_key" = "$2" ]
      then
        return 0
      fi
    done < "$1"
  fi
  settingsSet "$1" "$2" "$3"
}

# removes the key $2 from the overrides file $1, so the default applies again
settingsUnset() {
  if ! settingsValidKey "$2"
  then
    echo "invalid setting key '$2'" >&2
    return 1
  fi
  if ! [ -e "$1" ]
  then
    return 0
  fi
  if ! settings_unset_rest="$(settingsWithout "$1" "$2")"
  then
    return 1
  fi
  if [ "$settings_unset_rest" = "" ]
  then
    : | fileWriteAtomic "$1"
    return
  fi
  printf '%s\n' "$settings_unset_rest" | fileWriteAtomic "$1"
}
