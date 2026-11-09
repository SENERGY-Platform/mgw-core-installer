#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# Render (PLAN.md 4): one generic loop from a version's assets/templates to its config, which mirrors
# it. Files ending in .tmpl are rendered with the settings (the suffix is dropped), all other files
# are copied unchanged, e.g. the nginx templates (*.template) that nginx fills in itself. Every output
# file gets its template's mode, so the cron script stays executable. Only enabled integrations are
# rendered, so "in config" always means "wanted".
#
# envsubst only replaces the variables the render provides (render_vars); any other $NAME, e.g. one
# meant for the program reading the file, stays as it is. The variables are exported only in the
# subshell running envsubst, so passwords don't reach the environment of later commands.
#
# Variables: every setting, uppercased (gateway_port -> GATEWAY_PORT); the images from options
# (NGINX_IMG ...); and the derived values below. Paths into the version go through current, never a
# vX_Y_Z folder: a version is rendered before current points to it (PLAN.md 4).
#
# Needs lib/settings.sh with the settings loaded, and the version's options sourced (images).

# settings_keys comes from lib/settings.sh, images from options
# shellcheck disable=SC2154

# settings the install fills in; rendering without them would produce a config with blanks
render_required="core_id core_name stack_name host_dir_repository_path core_usr_pw core_db_pw core_db_root_pw"

# the template folder of each integration and the setting that enables it
render_integrations="systemd-units:systemd logrotate:logrotate cron:cron avahi:advertise"

# the folders whose files the reconcile links into /etc, and the separator after the core name that
# their file names get. A file in config has the same name as its link in /etc: systemd treats a
# unit link whose target has another name as an alias, and "systemctl enable" doesn't accept it as the
# unit file (checked with systemd 257). The core-owned units in systemd-units/core keep their names;
# the install names those itself.
render_linked="systemd-units/services:- logrotate:_ cron:_ avahi:_"

# exports the render variables for the core root $1, the version $2 (e.g. v1.3.0) and its folder
# name $3 (e.g. v1_3_0), and sets render_vars to the list envsubst gets. Meant for a subshell.
renderExport() {
  for render_key in ${render_required}
  do
    if [ "$(settingsGet "$render_key")" = "" ]
    then
      echo "setting '$render_key' is empty, not rendering" >&2
      return 1
    fi
  done
  render_vars=""
  for render_key in ${settings_keys}
  do
    render_name="$(printf '%s' "$render_key" | tr '[:lower:]' '[:upper:]')"
    render_value="$(settingsGet "$render_key")"
    renderVar "$render_name" "$render_value"
  done
  render_kratos_img=""
  for render_image in ${images}
  do
    renderVar "${render_image%%=*}" "${render_image#*=}"
    if [ "${render_image%%=*}" = "KRATOS_IMG" ]
    then
      render_kratos_img="${render_image#*=}"
    fi
  done
  # the core-manager's config needs kratos' version, which is the tag of its image
  renderVar KRATOS_VERSION "${render_kratos_img##*:}"
  renderVar VERSION "$2"
  renderVar VERSION_FOLDER "$3"
  renderVar CORE_ROOT "$1"
  renderVar STATE_PATH "$1/state"
  renderVar LOG_PATH "$1/log"
  renderVar SOCKETS_PATH "$1/sockets"
  renderVar MOUNTS_PATH "$1/mounts"
  renderVar DEPLOYMENTS_PATH "$1/deployments"
  renderVar SECRETS_PATH "/mnt/$(settingsGet core_name)/secrets"
  renderVar ASSETS_PATH "$1/current/assets"
  renderVar BIN_PATH "$1/current/bin"
  renderVar CONFIG_PATH "$1/current/config"
}

# prints the path $1 (relative to config) with the core name in front of the file name if the file
# is directly in one of the linked folders, e.g. cron/update -> cron/mgw_abc_update
renderName() {
  for render_item in ${render_linked}
  do
    if [ "${1%/*}" = "${render_item%%:*}" ]
    then
      echo "${1%/*}/$(settingsGet core_name)${render_item#*:}${1##*/}"
      return
    fi
  done
  echo "$1"
}

renderVar() {
  eval "export $1=\$2"
  render_vars="${render_vars:+$render_vars }\$$1"
}

# returns 0 if the template folder $1 (relative to assets/templates) belongs to no integration or to
# an enabled one
renderWanted() {
  for render_item in ${render_integrations}
  do
    case "$1" in
      "${render_item%%:*}"|"${render_item%%:*}"/*)
        [ "$(settingsGet "${render_item#*:}")" = "true" ]
        return
    esac
  done
  return 0
}

# renders the templates of the version folder $1 into $1/config: core root $2, version $3, version
# folder name $4. Writes $1/config.new completely, then swaps it in (see renderRepair). Returns 1 and
# leaves the old config in place if anything fails.
renderVersion() {
  render_src="$1/assets/templates"
  render_dst="$1/config.new"
  if ! [ -d "$render_src" ]
  then
    echo "no templates in '$1/assets'" >&2
    return 1
  fi
  if ! rm -rf "$render_dst" || ! mkdir "$render_dst"
  then
    echo "cannot create '$render_dst'" >&2
    return 1
  fi
  if ! (
    renderExport "$2" "$3" "$4" || exit 1
    cd "$render_src" || exit 1
    find . -type f | sort | while IFS= read -r render_file
    do
      render_rel="${render_file#./}"
      if ! renderWanted "$render_rel"
      then
        continue
      fi
      render_out="$render_dst/$(renderName "${render_rel%.tmpl}")"
      mkdir -p "${render_out%/*}" || exit 1
      case "$render_rel" in
        *.tmpl)
          envsubst "$render_vars" < "$render_rel" > "$render_out" || exit 1
          chmod --reference="$render_rel" "$render_out" || exit 1
          ;;
        *)
          cp -p "$render_rel" "$render_out" || exit 1
      esac
    done
  )
  then
    echo "rendering '$1' failed" >&2
    rm -rf "$render_dst"
    return 1
  fi
  renderSwap "$1"
}

# replaces $1/config with the complete $1/config.new: config -> config.old, config.new -> config,
# config.old removed. An interruption between the renames is finished by renderRepair.
renderSwap() {
  if [ -e "$1/config" ] && ! { rm -rf "$1/config.old" && mv "$1/config" "$1/config.old"; }
  then
    echo "cannot move '$1/config' aside" >&2
    return 1
  fi
  if ! mv "$1/config.new" "$1/config"
  then
    echo "cannot move '$1/config.new' into place" >&2
    return 1
  fi
  rm -rf "$1/config.old"
}

# finishes or undoes an interrupted render in the version folder $1. config.new is only renamed when
# complete, so without config a config.new is the new one, otherwise config.old the old one. Leftovers
# are removed.
renderRepair() {
  if ! [ -e "$1/config" ]
  then
    if [ -d "$1/config.new" ]
    then
      mv "$1/config.new" "$1/config" || return 1
    elif [ -d "$1/config.old" ]
    then
      mv "$1/config.old" "$1/config" || return 1
    fi
  fi
  rm -rf "$1/config.new" "$1/config.old"
}
