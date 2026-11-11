#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# The parts of the migration (PLAN.md 15, migration.md, m7-migration.md) that only read the old
# installation or write its files: the checks, the settings mapping, whether the old core runs, and
# the old .update_status. Only migration.sh uses this file; it goes when the migration goes.
#
# The old installation is the flat layout of the old installer (v0.30.0-alpha1 and later): .settings
# (shell assignments, parsed here, never sourced), .version, .units or .pid, container/.env.
#
# Needs lib/settings.sh (with the new version's defaults loaded), lib/state.sh, lib/host.sh,
# lib/semver.sh, lib/setup.sh (setupValidate) and jq.

# the old values are read and set through eval; settings_* come from lib/settings.sh
# shellcheck disable=SC2034,SC2154

# the oldest installed version that is migrated (migration.md decision 4, m7-migration.md finding 3)
migration_min_version="v0.30.0-alpha1"

# the settings carried over from the old .settings unchanged, pinned in state/settings (8)
migration_keys="core_id core_name stack_name host_dir_repository_path gateway_port subnet_core subnet_module subnet_gateway core_usr core_usr_pw core_db_pw core_db_root_pw logrotate cron advertise allow_beta"

# the old container/.env variables and the settings they became (m2: the container settings); the old
# name of the access log variable had a typo
migration_env="AUTH_SERVICE_LOG_LEVEL:auth_service_log_level
MODULE_MANAGER_LOG_LEVEL:module_manager_log_level
MODULE_MANGER_HTTP_ACCESS_LOG:module_manager_http_access_log
MODULE_MANAGER_DEP_STARTUP_DELAY:module_manager_dep_startup_delay
MODULE_MANAGER_AUX_DEP_STARTUP_DELAY:module_manager_aux_dep_startup_delay
SECRET_MANAGER_LOG_LEVEL:secret_manager_log_level
KRATOS_LOG_LEVEL:kratos_log_level
KRATOS_MIGRATE_LOG_LEVEL:kratos_migrate_log_level"

# the old installer's tmpfs size, fixed in its mount unit and ctrl.sh
migration_secrets_size=100M

# reads the old .settings of the installation $1 into the variables mig_o_<key>. Lines that aren't
# assignments are skipped; quotes around a value are removed (the old installer wrote none, a user
# may have). Returns 1 if the file can't be read.
migrationReadOld() {
  if ! [ -r "$1/.settings" ]
  then
    echo "cannot read '$1/.settings'" >&2
    return 1
  fi
  migration_old_keys=""
  while IFS= read -r migration_line || [ -n "$migration_line" ]
  do
    settingsParseLine "$migration_line" || continue
    case "$settings_line_value" in
      \"*\"|\'*\')
        settings_line_value="${settings_line_value#?}"
        settings_line_value="${settings_line_value%?}"
    esac
    eval "mig_o_$settings_line_key=\$settings_line_value"
    migration_old_keys="${migration_old_keys:+$migration_old_keys }$settings_line_key"
  done < "$1/.settings"
}

# prints the old value of the key $1
migrationOld() {
  eval "printf '%s\n' \"\$mig_o_$1\""
}

# prints the installed version of the installation $1 (its .version), fails if there is none
migrationVersion() {
  migration_version="$(cat "$1/.version" 2> /dev/null)"
  if [ "$migration_version" = "" ]
  then
    echo "cannot read '$1/.version'" >&2
    return 1
  fi
  printf '%s\n' "$migration_version"
}

# returns 0 if the installed version $1 can be migrated; otherwise prints why
migrationVersionOk() {
  if ! semverValid "$1"
  then
    echo "the installed version '$1' isn't a release; only releases from $migration_min_version on are migrated"
    return 1
  fi
  if semverLess "$1" "$migration_min_version"
  then
    echo "the installed version $1 is older than $migration_min_version"
    return 1
  fi
}

# prints the way forward for an installation too old to migrate (migration.md decision 4)
migrationTooOldHelp() {
  echo "update it by hand to an old-layout release from v0.30.0 on first: download that release's archive, extract it and run its assets/scripts/update.sh -path=$1; the next update then migrates it"
}

# reports the problem $1 of migrationCheck
migrationProblem() {
  echo "$1"
  migration_check_rc=1
}

# checks the old settings (read with migrationReadOld) of the installation in the folder $1 against
# what the new layout depends on: the paths it derives or fixes, the values the render needs, the
# names, systemd as true or false. Prints every problem, one per line; returns 1 if there is one.
# Nothing is changed.
migrationCheck() {
  migration_check_rc=0
  # the paths the new layout derives from the core root or fixes (m7-migration.md, finding 6)
  migration_cn="$(migrationOld core_name)"
  for migration_pair in "base_path:$1" "secrets_path:/mnt/$migration_cn/secrets" \
    "deployments_path:$1/deployments" "sockets_path:$1/sockets" "log_path:$1/log" "mounts_path:$1/mounts" \
    "bin_path:$1/bin" "container_path:$1/container" "scripts_path:$1/scripts" \
    "systemd_path:$host_systemd_path" "logrotated_path:$host_logrotated_path" "cron_path:$host_cron_path" \
    "avahi_path:$host_avahi_path" "docker_socket_path:$host_docker_socket"
  do
    migration_key="${migration_pair%%:*}"
    migration_want="${migration_pair#*:}"
    migration_have="$(migrationOld "$migration_key")"
    if [ "${migration_have%/}" != "$migration_want" ]
    then
      migrationProblem "$migration_key is '$migration_have', the new layout needs $migration_want"
    fi
  done
  # the values the render needs (render_required)
  for migration_key in core_id core_name stack_name host_dir_repository_path core_usr_pw core_db_pw core_db_root_pw
  do
    if [ "$(migrationOld "$migration_key")" = "" ]
    then
      migrationProblem "$migration_key is empty"
    fi
  done
  # the names become parts of compose project, folder, unit and volume names in the new layout. The
  # other values are carried over unchecked: they work in the old layout, which renders them the same
  # way, and the passwords are stored in the databases, so a refusal couldn't be fixed.
  for migration_key in core_id core_name stack_name
  do
    migration_have="$(migrationOld "$migration_key")"
    if [ "$migration_have" != "" ] && ! migration_why="$(setupValidate "$migration_key" "$migration_have" 2>&1)"
    then
      migrationProblem "$migration_why"
    fi
  done
  case "$(migrationOld systemd)" in
    true|false)
      ;;
    *)
      migrationProblem "systemd is '$(migrationOld systemd)', true or false is needed"
  esac
  return $migration_check_rc
}

# prints the settings of the new layout for the old installation in $1, one key=value per line: the
# old settings carried over (migrationReadOld first), systemd as autostart, the old tmpfs size, and
# the container settings from the old container/.env where they differ from the new defaults (the new
# version's defaults must be loaded). A container value the new layout doesn't accept is left out with
# a warning on stderr.
migrationSettings() {
  for migration_key in ${migration_keys}
  do
    printf '%s=%s\n' "$migration_key" "$(migrationOld "$migration_key")"
  done
  printf 'autostart=%s\n' "$(migrationOld systemd)"
  printf 'secrets_size=%s\n' "$migration_secrets_size"
  if ! [ -r "$1/container/.env" ]
  then
    return 0
  fi
  while IFS= read -r migration_line || [ -n "$migration_line" ]
  do
    migration_line="${migration_line%"$settings_cr"}"
    case "$migration_line" in
      *=*)
        ;;
      *)
        continue
    esac
    migration_var="${migration_line%%=*}"
    migration_value="${migration_line#*=}"
    migration_key="$(printf '%s\n' "$migration_env" | sed -n "s/^$migration_var:\(.*\)\$/\1/p")"
    if [ "$migration_key" = "" ] || ! settingsKnown "$migration_key"
    then
      continue
    fi
    if [ "$migration_value" = "$(settingsGet "$migration_key")" ]
    then
      continue
    fi
    if ! setupValidate "$migration_key" "$migration_value" 2> /dev/null
    then
      echo "warning: $migration_var=$migration_value in container/.env isn't a valid $migration_key, the default applies" >&2
      continue
    fi
    printf '%s=%s\n' "$migration_key" "$migration_value"
  done < "$1/container/.env"
}

# returns 0 if the old core of the installation $1 runs (m7-migration.md, finding 7): with systemd one
# of the service units in .units is active, without one of the processes in .pid runs a binary of
# the installation (the pids may be stale after a reboot, as the old ctrl.sh knew)
migrationWasRunning() {
  if [ "$(migrationOld systemd)" = "true" ]
  then
    [ -r "$1/.units" ] || return 1
    while IFS= read -r migration_unit || [ -n "$migration_unit" ]
    do
      case "$migration_unit" in
        *.service)
          if systemctl is-active --quiet "$migration_unit" 2> /dev/null
          then
            return 0
          fi
      esac
    done < "$1/.units"
    return 1
  fi
  [ -r "$1/.pid" ] || return 1
  # the old ctrl.sh wrote one pid per line
  while IFS= read -r migration_pid || [ -n "$migration_pid" ]
  do
    case "$migration_pid" in
      ""|*[!0-9]*)
        continue
    esac
    migration_cmd="$({ tr '\0' '\n' < "/proc/$migration_pid/cmdline" | head -n 1; } 2> /dev/null)"
    case "$migration_cmd" in
      "$1/bin/"*)
        return 0
    esac
  done < "$1/.pid"
  return 1
}

# writes the old installer's record .update_status into the installation $1 (migration.md decision
# 3: the old core-manager and the modules read it): result $2, step $3, from $4, to $5, started $6.
# A failed write is only reported.
migrationOldStatus() {
  if ! migration_status="$(jq -n -c --arg from_version "$4" --arg to_version "$5" --arg started "$6" \
    --arg finished "$(stateNow)" --arg result "$2" --arg step "$3" \
    '{from_version: $from_version, to_version: $to_version, started: $started, finished: $finished, result: $result, step: $step}')" ||
    ! printf '%s\n' "$migration_status" | fileWriteAtomic "$1/.update_status" 644
  then
    echo "warning: cannot write '$1/.update_status'" >&2
  fi
}
