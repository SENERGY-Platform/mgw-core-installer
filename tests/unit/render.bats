#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

load helpers

ASSETS="$BATS_TEST_DIRNAME/../../assets"

# a version folder V with its own small templates, settings with every required value
setup() {
  export ROOT="$BATS_TEST_TMPDIR/core" V="$BATS_TEST_TMPDIR/core/v1_3_0"
  mkdir -p "$V/assets/templates/host-binaries/x" "$V/assets/templates/cron" "$V/assets/templates/avahi" \
    "$V/assets/templates/container/configs/gateway/template"
  printf '%s\n' 'core_id=' 'core_name=' 'stack_name=' 'host_dir_repository_path=' 'core_usr_pw=' 'core_db_pw=' \
    'core_db_root_pw=' 'gateway_port=8080' 'cron=true' 'advertise=false' 'logrotate=true' 'systemd=true' > "$V/assets/settings.defaults"
  printf '%s\n' 'core_id=abc' 'core_name=mgw_abc' 'stack_name=mgw_abc' "host_dir_repository_path=$ROOT/repositories/host_dir" \
    'core_usr_pw=u' 'core_db_pw=d' 'core_db_root_pw=r' > "$BATS_TEST_TMPDIR/settings"
  printf '%s\n' 'images="' 'NGINX_IMG=nginx:1.31.1-alpine' 'KRATOS_IMG=oryd/kratos:v1.3.1' '"' > "$V/assets/options"
  printf '%s\n' '{"port": "${GATEWAY_PORT}", "id": "${CORE_ID}", "kratos": "${KRATOS_VERSION}",' \
    '"img": "${NGINX_IMG}", "bin": "${BIN_PATH}", "state": "${STATE_PATH}", "folder": "${VERSION_FOLDER}",' \
    '"secrets": "${SECRETS_PATH}", "other": "${NOT_A_SETTING}", "plain": "$HOME"}' > "$V/assets/templates/host-binaries/x/conf.json.tmpl"
  printf '%s\n' '#!/bin/sh' '${CORE_ROOT}/current/update.sh -a' > "$V/assets/templates/cron/mgw_update.tmpl"
  chmod 755 "$V/assets/templates/cron/mgw_update.tmpl"
  printf '%s\n' '<port>${GATEWAY_PORT}</port>' > "$V/assets/templates/avahi/core.service.tmpl"
  printf '%s\n' 'listen ${GATEWAY_PORT};' > "$V/assets/templates/container/configs/gateway/template/default.conf.template"
}

render() {
  dsh '. "$V/assets/options"; settingsLoad "$V/assets/settings.defaults" "$BATS_TEST_TMPDIR/settings" || exit 1; '"$1" file settings render
}

@test "a .tmpl is rendered with settings, images and derived values" {
  run render 'renderVersion "$V" "$ROOT" v1.3.0 v1_3_0'
  [ "$status" -eq 0 ]
  [ "$(cat "$V/config/host-binaries/x/conf.json")" = "$(printf '%s\n' '{"port": "8080", "id": "abc", "kratos": "v1.3.1",' \
    '"img": "nginx:1.31.1-alpine", "bin": "'"$ROOT"'/current/bin", "state": "'"$ROOT"'/state", "folder": "v1_3_0",' \
    '"secrets": "/mnt/mgw_abc/secrets", "other": "${NOT_A_SETTING}", "plain": "$HOME"}')" ]
  [ ! -e "$V/config/host-binaries/x/conf.json.tmpl" ]
}

@test "other files are copied unchanged, nginx templates included" {
  run render 'renderVersion "$V" "$ROOT" v1.3.0 v1_3_0'
  [ "$status" -eq 0 ]
  [ "$(cat "$V/config/container/configs/gateway/template/default.conf.template")" = 'listen ${GATEWAY_PORT};' ]
}

@test "output files keep their template's mode" {
  run render 'renderVersion "$V" "$ROOT" v1.3.0 v1_3_0'
  [ "$(stat -c %a "$V/config/cron/mgw_update")" = "755" ]
  [ "$(cat "$V/config/cron/mgw_update")" = "$(printf '%s\n' '#!/bin/sh' "$ROOT/current/update.sh -a")" ]
}

@test "only enabled integrations are rendered" {
  run render 'renderVersion "$V" "$ROOT" v1.3.0 v1_3_0'
  [ -e "$V/config/cron/mgw_update" ]
  [ ! -e "$V/config/avahi" ]
  printf '%s\n' 'cron=false' 'advertise=true' >> "$BATS_TEST_TMPDIR/settings"
  run render 'renderVersion "$V" "$ROOT" v1.3.0 v1_3_0'
  [ "$status" -eq 0 ]
  [ ! -e "$V/config/cron" ]
  [ "$(cat "$V/config/avahi/core.service")" = "<port>8080</port>" ]
}

@test "a missing required setting stops the render and keeps the old config" {
  run render 'renderVersion "$V" "$ROOT" v1.3.0 v1_3_0'
  printf '%s\n' 'core_db_pw=' >> "$BATS_TEST_TMPDIR/settings"
  run render 'renderVersion "$V" "$ROOT" v1.3.0 v1_3_0'
  [ "$status" -eq 1 ]
  [[ "$output" == *"setting 'core_db_pw' is empty"* ]]
  [ -e "$V/config/cron/mgw_update" ]
  [ ! -e "$V/config.new" ] && [ ! -e "$V/config.old" ]
}

@test "the variables don't reach the caller's environment" {
  run render 'renderVersion "$V" "$ROOT" v1.3.0 v1_3_0 && echo "[${CORE_DB_PW:-}][${GATEWAY_PORT:-}]"'
  [ "$output" = "[][]" ]
}

@test "repair: a swap interrupted after moving the old config aside finishes with the new one" {
  mkdir -p "$V/config.old" "$V/config.new"
  echo old > "$V/config.old/f"
  echo new > "$V/config.new/f"
  run render 'renderRepair "$V"'
  [ "$status" -eq 0 ]
  [ "$(cat "$V/config/f")" = "new" ]
  [ ! -e "$V/config.old" ] && [ ! -e "$V/config.new" ]
}

@test "repair: an interrupted render leaves the old config" {
  mkdir -p "$V/config" "$V/config.new"
  echo old > "$V/config/f"
  echo partial > "$V/config.new/f"
  run render 'renderRepair "$V"'
  [ "$(cat "$V/config/f")" = "old" ]
  [ ! -e "$V/config.new" ]
}

@test "repair: only an old config left" {
  mkdir -p "$V/config.old"
  echo old > "$V/config.old/f"
  run render 'renderRepair "$V"'
  [ "$(cat "$V/config/f")" = "old" ]
}

@test "the shipped templates render completely" {
  rm -rf "$V/assets"
  mkdir -p "$V/assets"
  cp -r "$ASSETS/templates" "$ASSETS/settings.defaults" "$ASSETS/options" "$V/assets/"
  run render 'renderVersion "$V" "$ROOT" v1.3.0 v1_3_0'
  [ "$status" -eq 0 ]
  # no variable of the render is left, nginx's own ones are
  ! grep -rq '\${[A-Z_]*}' "$V/config" --exclude='*.template'
  grep -q '\${GATEWAY_PORT}' "$V/config/container/configs/gateway/template/public_api.conf.template"
  for f in $(find "$V/config" -name '*.json'); do python3 -m json.tool "$f" > /dev/null; done
  [ "$(find "$V/config" -name '*.tmpl' | wc -l)" -eq 0 ]
  [ "$(find "$V/assets/templates" -type f | wc -l)" -eq "$(find "$V/config" -type f | wc -l)" ]
  [ -x "$V/config/cron/mgw_update" ]
  grep -qx "name: mgw_abc_v1_3_0" "$V/config/container/docker-compose.yml"
  grep -q '"version": "v1.3.1"' "$V/config/host-binaries/SENERGY-Platform/mgw-core-manager/conf.json"
}
