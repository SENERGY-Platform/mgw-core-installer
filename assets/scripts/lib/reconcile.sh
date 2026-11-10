#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# Reconcile (PLAN.md 5): make the integration links in /etc match <core root>/current/config. Not a
# list of actions and not a diff between versions, so it gives the right result from any starting
# state: after an update, a rollback, a half-done earlier reconcile, a manual change, or ctrl.sh
# switching an integration on or off.
#
# - What should be: every file in the integration folders of current/config gets a link in /etc,
#   pointing through current: <core root>/current/config/<folder>/<file>.
# - What is: the links in the /etc folders. Ours are recognised by their target (pointing into
#   <core root>/current/config/). Everything else is never touched, also not the core-owned plain
#   files (the secrets mount unit, the recovery unit).
# - A file without a link: create the link, and enable the unit if it is one.
# - A link of ours without a file: disable the unit if it is one, remove the link.
# - Both: make sure a unit is enabled; the link reaches the current version's file through current.
#
# Units are only ever enabled or disabled here, never during an update ("systemctl disable" also
# deletes linked unit files). After a change of unit links, systemd is reloaded. "systemctl enable"
# resolves the link and points the .wants link into the version folder; that's fine, systemd only
# uses the .wants link's name, also once the version folder is gone (checked with systemd 257).
#
# Needs lib/host.sh.

# reconciles the links of the core root $1. Returns 1 if anything couldn't be done (the rest is done
# anyway), after reporting it on stderr.
reconcileEtc() {
  reconcile_config="$1/current/config"
  reconcile_rc=0
  reconcile_units_changed=false
  reconcile_units=""
  # per integration folder in config: the /etc folder (lib/host.sh). A link has the same name as its
  # file; the render gives the files their final names (render_linked in lib/render.sh).
  # shellcheck disable=SC2154 # set by lib/host.sh
  reconcile_folders="systemd-units/services:$host_systemd_path logrotate:$host_logrotated_path cron:$host_cron_path avahi:$host_avahi_path"
  # without current's config, everything would look unwanted and be removed
  if ! [ -d "$reconcile_config" ]
  then
    echo "'$reconcile_config' not found, not reconciling" >&2
    return 1
  fi
  for reconcile_item in ${reconcile_folders}
  do
    reconcile_folder="${reconcile_item%%:*}"
    reconcile_etc="${reconcile_item#*:}"
    if ! reconcileFolder "$reconcile_config/$reconcile_folder" "$reconcile_etc" "$reconcile_folder"
    then
      reconcile_rc=1
    fi
  done
  if [ "$reconcile_units_changed" = "true" ] || [ "$reconcile_units" != "" ]
  then
    if ! systemctl daemon-reload
    then
      echo "systemctl daemon-reload failed" >&2
      reconcile_rc=1
    fi
    for reconcile_unit in ${reconcile_units}
    do
      if [ "$(systemctl is-enabled "$reconcile_unit" 2> /dev/null)" = "enabled" ]
      then
        continue
      fi
      echo "enabling $reconcile_unit ..."
      if ! systemctl enable "$reconcile_unit" > /dev/null 2>&1
      then
        echo "enabling $reconcile_unit failed" >&2
        reconcile_rc=1
      fi
    done
  fi
  return $reconcile_rc
}

# reconciles one integration: the files in $1 should be linked into the /etc folder $2 under their
# own names. $3 is the folder's name in config ("systemd-units/services" marks units).
reconcileFolder() {
  reconcile_folder_rc=0
  reconcile_is_unit=false
  if [ "$3" = "systemd-units/services" ]
  then
    reconcile_is_unit=true
  fi
  # ours without a file: remove
  if [ -d "$2" ]
  then
    for reconcile_link in "$2"/*
    do
      if ! [ -L "$reconcile_link" ]
      then
        continue
      fi
      reconcile_target="$(readlink "$reconcile_link")"
      case "$reconcile_target" in
        "$1"/*)
          ;;
        *)
          continue
      esac
      reconcile_name="${reconcile_link##*/}"
      if [ -f "$reconcile_target" ] && [ "$reconcile_name" = "${reconcile_target##*/}" ]
      then
        continue
      fi
      if [ "$reconcile_is_unit" = "true" ]
      then
        reconcile_units_changed=true
        reconcileDisable "$2" "$reconcile_name"
      fi
      echo "removing $reconcile_link ..."
      if ! rm -f "$reconcile_link"
      then
        echo "removing $reconcile_link failed" >&2
        reconcile_folder_rc=1
      fi
    done
  fi
  # a file without its link: create it
  if ! [ -d "$1" ]
  then
    return $reconcile_folder_rc
  fi
  for reconcile_file in "$1"/*
  do
    if ! [ -f "$reconcile_file" ]
    then
      continue
    fi
    reconcile_name="${reconcile_file##*/}"
    reconcile_link="$2/$reconcile_name"
    if [ "$reconcile_is_unit" = "true" ]
    then
      reconcile_units="${reconcile_units:+$reconcile_units }$reconcile_name"
    fi
    if [ -L "$reconcile_link" ] && [ "$(readlink "$reconcile_link")" = "$reconcile_file" ]
    then
      continue
    fi
    if [ -e "$reconcile_link" ] || [ -L "$reconcile_link" ]
    then
      echo "$reconcile_link exists and isn't ours, leaving it alone" >&2
      reconcile_folder_rc=1
      continue
    fi
    if ! [ -d "$2" ]
    then
      echo "'$2' not found, cannot link $reconcile_name" >&2
      reconcile_folder_rc=1
      continue
    fi
    echo "linking $reconcile_link ..."
    if ! ln -s "$reconcile_file" "$reconcile_link"
    then
      echo "linking $reconcile_link failed" >&2
      reconcile_folder_rc=1
      continue
    fi
    if [ "$reconcile_is_unit" = "true" ]
    then
      reconcile_units_changed=true
    fi
  done
  return $reconcile_folder_rc
}

# disables the unit $2 whose file is linked in the systemd folder $1. If systemctl can't (e.g. the
# link's target is gone), the unit's links in the .wants and .requires folders are removed directly.
reconcileDisable() {
  echo "disabling $2 ..."
  if systemctl disable "$2" > /dev/null 2>&1
  then
    return 0
  fi
  find "$1" -mindepth 2 -maxdepth 2 -type l -name "$2" \( -path '*.wants/*' -o -path '*.requires/*' \) -delete
}
