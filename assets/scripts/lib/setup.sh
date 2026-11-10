#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# The parts of the install that are specific to it (PLAN.md 10a): the install's choices (config file
# or questions), their validation, the search for unfinished installs and the package check.
#
# The choices are kept as overrides of the version's defaults (setupSet, setupGet) until the core
# root exists and they are written into state/settings.
#
# Needs lib/settings.sh (with the version's defaults loaded), lib/state.sh, lib/lock.sh.

# settings_* come from lib/settings.sh, setup_inst_* are set by recordLoad, setup_pinned is used by
# setup.sh
# shellcheck disable=SC2034,SC2154

# keys of the config file that are no settings
setup_keys="install_dir start_core skip_pkg_install_confirm"

# settings the install writes into state/settings even when they keep their default (pinning, 8)
setup_pinned="core_id core_name stack_name host_dir_repository_path gateway_port subnet_core subnet_module subnet_gateway core_usr core_usr_pw core_db_pw core_db_root_pw secrets_size autostart logrotate cron advertise allow_beta"

# the keys that were set (config file or questions), in order
setup_set=""

setupKnown() {
  for setup_known in ${setup_keys} ${settings_keys}
  do
    if [ "$setup_known" = "$1" ]
    then
      return 0
    fi
  done
  return 1
}

# sets the key $1 to $2
setupSet() {
  eval "setup_v_$1=\$2"
  case " $setup_set " in
    *" $1 "*)
      ;;
    *)
      setup_set="${setup_set:+$setup_set }$1"
  esac
}

# prints the value of the key $1: set, otherwise the default (empty for the install's own keys)
setupGet() {
  case " $setup_set " in
    *" $1 "*)
      eval "printf '%s\n' \"\$setup_v_$1\""
      return
  esac
  for setup_get in ${setup_keys}
  do
    if [ "$setup_get" = "$1" ]
    then
      echo
      return
    fi
  done
  settingsGet "$1"
}

# reads the config file $1 (the format of the settings: key=value, the value taken literally). Fails
# on a line that isn't a setting or the install's own key, naming the line; a config file of the old
# installer (sourced shell code) fails that way.
configLoad() {
  if ! [ -r "$1" ]
  then
    echo "cannot read config file '$1'" >&2
    return 1
  fi
  config_rc=0
  config_n=0
  while IFS= read -r config_line || [ -n "$config_line" ]
  do
    config_n=$((config_n + 1))
    config_line="${config_line%"$settings_cr"}"
    case "$config_line" in
      ""|"#"*)
        continue
    esac
    if ! settingsParseLine "$config_line" || ! setupKnown "$settings_line_key"
    then
      echo "$1, line $config_n: not a known setting: '$config_line'" >&2
      config_rc=1
      continue
    fi
    setupSet "$settings_line_key" "$settings_line_value"
  done < "$1"
  if [ $config_rc -ne 0 ]
  then
    echo "the config file has the format of the settings (key=value, no quotes, see assets/setup.conf.example)" >&2
  fi
  return $config_rc
}

# --- validation ---

# prints the integer of the IPv4 address $1, fails if it isn't one
ipv4Int() {
  case "$1" in
    *[!0-9.]*|.*|*.|*..*)
      return 1
  esac
  ipv4_rest="$1"
  ipv4_int=0
  for ipv4_i in 1 2 3 4
  do
    ipv4_part="${ipv4_rest%%.*}"
    if [ "$ipv4_part" = "" ] || [ "${#ipv4_part}" -gt 3 ] || [ "$ipv4_part" -gt 255 ]
    then
      return 1
    fi
    ipv4_int=$((ipv4_int * 256 + ipv4_part))
    if [ "$ipv4_i" -lt 4 ]
    then
      [ "$ipv4_rest" != "$ipv4_part" ] || return 1
      ipv4_rest="${ipv4_rest#*.}"
    elif [ "$ipv4_rest" != "$ipv4_part" ]
    then
      return 1
    fi
  done
  echo "$ipv4_int"
}

# returns 0 if $1 is the network address of a subnet with the prefix $2 (aligned)
subnetValid() {
  subnet_int="$(ipv4Int "$1")" || return 1
  [ $((subnet_int % (1 << (32 - $2)))) -eq 0 ]
}

# returns 0 if the subnets $1 and $2 (address/prefix) overlap
subnetsOverlap() {
  overlap_a="$(ipv4Int "${1%/*}")" || return 1
  overlap_b="$(ipv4Int "${2%/*}")" || return 1
  overlap_a_end=$((overlap_a + (1 << (32 - ${1#*/})) - 1))
  overlap_b_end=$((overlap_b + (1 << (32 - ${2#*/})) - 1))
  [ "$overlap_a" -le "$overlap_b_end" ] && [ "$overlap_b" -le "$overlap_a_end" ]
}

setupInvalid() {
  case "$2" in
    \"*|\'*)
      echo "invalid $1 '$2': $3 (the config file takes values without quotes)" >&2
      ;;
    *)
      echo "invalid $1 '$2': $3" >&2
  esac
  return 1
}

# checks the value $2 of the key $1; prints why it is invalid and returns 1
setupValidate() {
  case "$1" in
    core_id|core_name|stack_name)
      case "$2" in
        ""|[!a-z0-9]*|*[!a-z0-9_-]*)
          setupInvalid "$1" "$2" "lowercase letters, digits, - and _ only, starting with a letter or digit"
          return
      esac
      ;;
    install_dir|host_dir_repository_path)
      case "$2" in
        /*[!/]*)
          ;;
        *)
          setupInvalid "$1" "$2" "an absolute path is needed"
          return
      esac
      case "$2" in
        *[!A-Za-z0-9/._-]*|*/../*|*/..|*/./*)
          setupInvalid "$1" "$2" "letters, digits and / . _ - only, no . or .. parts"
          return
      esac
      ;;
    gateway_port)
      case "$2" in
        ""|*[!0-9]*|0*)
          setupInvalid "$1" "$2" "a port number from 1 to 65535 is needed"
          return
      esac
      if [ "${#2}" -gt 5 ] || [ "$2" -gt 65535 ]
      then
        setupInvalid "$1" "$2" "a port number from 1 to 65535 is needed"
        return
      fi
      ;;
    subnet_core|subnet_gateway|subnet_module)
      setup_prefix=28
      [ "$1" = "subnet_module" ] && setup_prefix=16
      if ! subnetValid "$2" "$setup_prefix"
      then
        setupInvalid "$1" "$2" "the network address of a /$setup_prefix subnet is needed (e.g. 10.0.0.0)"
        return
      fi
      ;;
    core_usr_pw|core_db_pw|core_db_root_pw)
      case "$2" in
        *[!A-Za-z0-9._~+-]*)
          setupInvalid "$1" "(hidden)" "letters, digits and . _ ~ + - only"
          return
      esac
      if [ "${#2}" -lt 8 ]
      then
        setupInvalid "$1" "(hidden)" "at least 8 characters"
        return
      fi
      ;;
    core_usr)
      case "$2" in
        ""|*[!A-Za-z0-9._~+-]*)
          setupInvalid "$1" "$2" "letters, digits and . _ ~ + - only"
          return
      esac
      ;;
    update_retry_limit)
      case "$2" in
        ""|*[!0-9]*|0*)
          setupInvalid "$1" "$2" "a number from 1 up is needed"
          return
      esac
      ;;
    secrets_size)
      case "${2%[kKmMgG]}" in
        ""|0*|*[!0-9]*)
          setupInvalid "$1" "$2" "a size like 100M (a number, optionally with k, m or g) is needed"
          return
      esac
      ;;
    *_log_level)
      case "$2" in
        ""|*[!a-z]*)
          setupInvalid "$1" "$2" "a log level like warning, lowercase letters only"
          return
      esac
      ;;
    *_delay)
      case "$2" in
        *[smh])
          ;;
        *)
          setupInvalid "$1" "$2" "a duration like 20s, 5m or 1h is needed"
          return
      esac
      case "${2%[smh]}" in
        ""|*[!0-9]*)
          setupInvalid "$1" "$2" "a duration like 20s, 5m or 1h is needed"
          return
      esac
      ;;
    autostart|logrotate|cron|advertise|allow_beta|start_core|skip_pkg_install_confirm|module_manager_http_access_log)
      case "$2" in
        true|false)
          ;;
        *)
          setupInvalid "$1" "$2" "true or false"
          return
      esac
      ;;
  esac
  return 0
}

# checks every value that was set, and the subnets against each other. Prints every problem.
setupValidateAll() {
  setup_va_rc=0
  for setup_va_key in ${setup_set}
  do
    # the generated values are only checked once they exist
    if [ "$(setupGet "$setup_va_key")" = "" ]
    then
      continue
    fi
    setupValidate "$setup_va_key" "$(setupGet "$setup_va_key")" || setup_va_rc=1
  done
  if [ $setup_va_rc -eq 0 ]
  then
    setup_va_c="$(setupGet subnet_core)/28"
    setup_va_g="$(setupGet subnet_gateway)/28"
    setup_va_m="$(setupGet subnet_module)/16"
    if subnetsOverlap "$setup_va_c" "$setup_va_g" || subnetsOverlap "$setup_va_c" "$setup_va_m" || subnetsOverlap "$setup_va_g" "$setup_va_m"
    then
      echo "the core, gateway and module subnets overlap ($setup_va_c, $setup_va_g, $setup_va_m)" >&2
      setup_va_rc=1
    fi
  fi
  if [ "$(setupGet stack_name)" != "" ] && [ "$(setupGet stack_name)" != "$(setupGet core_name)" ]
  then
    echo "stack_name must equal core_name for a new installation; it only differs on installations older than this installer (see settings.defaults)" >&2
    setup_va_rc=1
  fi
  return $setup_va_rc
}

# returns 0 if the TCP port $1 is in use: something listens on it, or a container publishes it
setupPortInUse() {
  [ "$(ss -ltnH "sport = :$1" 2> /dev/null)" != "" ] || docker ps --format '{{.Ports}}' 2> /dev/null | grep -q ":$1->"
}

# --- unfinished installs ---

# prints the core roots in the install directory $1 whose install didn't record success and whose
# lock is free: their install was killed (PLAN.md 10a, step 2). A held lock means the install is still
# running; it is left alone.
setupUnfinished() {
  for setup_root in "$1"/*
  do
    if ! [ -f "$setup_root/state/install" ]
    then
      continue
    fi
    recordClear setup_inst "result" ""
    recordLoad "$setup_root/state/install" setup_inst "" 2> /dev/null
    if [ "$setup_inst_result" = "success" ]
    then
      continue
    fi
    if lockHeld "$setup_root/state/lock"
    then
      continue
    fi
    echo "$setup_root"
  done
}

# --- packages ---

# prints the packages of the list $1 (<package>:<command>, the command defaulting to the package's
# name) whose command is missing
setupMissingPkg() {
  setup_missing=""
  for setup_item in ${1}
  do
    setup_cmd="${setup_item#*:}"
    if [ "$setup_cmd" = "" ]
    then
      setup_cmd="${setup_item%%:*}"
    fi
    if ! command -v "$setup_cmd" > /dev/null 2>&1
    then
      setup_missing="${setup_missing:+$setup_missing }${setup_item%%:*}"
    fi
  done
  echo "$setup_missing"
}
