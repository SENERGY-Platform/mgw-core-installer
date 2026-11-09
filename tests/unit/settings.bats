#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

load helpers

setup() {
  export D="$BATS_TEST_TMPDIR/settings.defaults" S="$BATS_TEST_TMPDIR/settings"
  printf '%s\n' '# defaults' 'gateway_port=8080' 'core_name=' 'allow_beta=false' 'log_level=warning' > "$D"
}

settings() {
  dsh "$1" file settings
}

@test "defaults only" {
  run settings 'settingsLoad "$D" "$S" && echo "[$(settingsGet gateway_port)]" && echo "[$(settingsGet core_name)]" && echo "[$settings_keys]"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "[8080]" ]
  [ "${lines[1]}" = "[]" ]
  [ "${lines[2]}" = "[gateway_port core_name allow_beta log_level]" ]
  run settings 'settingsLoad "$D" "$S" && settingsIsSet gateway_port'
  [ "$status" -eq 1 ]
}

@test "state/settings overrides the defaults" {
  printf '%s\n' 'gateway_port=9090' 'core_name=mgw_abc' > "$S"
  run settings 'settingsLoad "$D" "$S" && settingsGet gateway_port && settingsGet core_name && settingsGet allow_beta && settingsIsSet core_name && ! settingsIsSet allow_beta'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '9090\nmgw_abc\nfalse')" ]
}

@test "an empty value in state/settings overrides a default" {
  printf '%s\n' 'log_level=' > "$S"
  run settings 'settingsLoad "$D" "$S" && echo "[$(settingsGet log_level)]" && settingsIsSet log_level'
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "keys the version doesn't know are ignored when reading" {
  printf '%s\n' 'added_by_a_newer_version=1' > "$S"
  run settings 'settingsLoad "$D" "$S" && settingsGet added_by_a_newer_version'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown setting 'added_by_a_newer_version'"* ]]
}

@test "values are taken literally, never executed" {
  printf '%s\n' "core_name=\$(touch $BATS_TEST_TMPDIR/executed) \"quoted\" a=b 'x'" > "$S"
  run settings 'settingsLoad "$D" "$S" && settingsGet core_name'
  [ "$status" -eq 0 ]
  [ "$output" = "\$(touch $BATS_TEST_TMPDIR/executed) \"quoted\" a=b 'x'" ]
  [ ! -e "$BATS_TEST_TMPDIR/executed" ]
}

@test "comments, empty lines, invalid keys and windows line endings" {
  printf '%s\r\n' '# gateway_port=1' '' 'no separator' 'Gateway_port=2' '1gateway_port=3' 'gateway-port=4' '=5' 'gateway_port=6060' > "$S"
  run settings 'settingsLoad "$D" "$S" && echo "[$(settingsGet gateway_port)]"'
  [ "$status" -eq 0 ]
  [ "$output" = "[6060]" ]
}

@test "a repeated key keeps its last value" {
  printf '%s\n' 'gateway_port=1' 'gateway_port=2' > "$S"
  run settings 'settingsLoad "$D" "$S" && settingsGet gateway_port'
  [ "$output" = "2" ]
}

@test "a file without a trailing line break" {
  printf 'gateway_port=7070' > "$S"
  run settings 'settingsLoad "$D" "$S" && settingsGet gateway_port'
  [ "$output" = "7070" ]
}

@test "missing defaults fail, missing state/settings doesn't" {
  run settings 'settingsLoad "$D.missing" "$S"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot read settings defaults"* ]]
  run settings 'settingsLoad "$D" "$S.missing"'
  [ "$status" -eq 0 ]
}

@test "loading again forgets the keys of the previous defaults" {
  printf '%s\n' 'other=1' > "$BATS_TEST_TMPDIR/other.defaults"
  run settings 'settingsLoad "$D" "$S" && settingsLoad "$BATS_TEST_TMPDIR/other.defaults" "$S" && echo "[$settings_keys]" && settingsGet gateway_port'
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "[other]" ]
}

@test "set adds a key, replaces every earlier value and keeps everything else" {
  printf '%s\n' '# a comment' 'gateway_port=1' 'added_by_a_newer_version=x' 'gateway_port=2' > "$S"
  run settings 'settingsSet "$S" gateway_port 9090 && settingsSet "$S" core_name mgw_abc'
  [ "$status" -eq 0 ]
  [ "$(cat "$S")" = "$(printf '%s\n' '# a comment' 'added_by_a_newer_version=x' 'gateway_port=9090' 'core_name=mgw_abc')" ]
}

@test "set creates a missing file with mode 600 and leaves no temp file" {
  run settings 'settingsSet "$S" core_usr_pw secret'
  [ "$status" -eq 0 ]
  [ "$(cat "$S")" = "core_usr_pw=secret" ]
  [ "$(stat -c %a "$S")" = "600" ]
  [ "$(ls "$BATS_TEST_TMPDIR" | grep -c tmp)" -eq 0 ]
}

@test "set refuses invalid keys and line breaks" {
  run settings 'settingsSet "$S" Bad 1'
  [ "$status" -eq 1 ]
  run settings 'settingsSet "$S" good "$(printf "a\nb")"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"line break"* ]]
  [ ! -e "$S" ]
}

@test "add only adds a missing key, it never changes one" {
  printf '%s\n' 'gateway_port=9090' > "$S"
  run settings 'settingsAdd "$S" gateway_port 8080 && settingsAdd "$S" secrets_size 100M'
  [ "$status" -eq 0 ]
  [ "$(cat "$S")" = "$(printf '%s\n' 'gateway_port=9090' 'secrets_size=100M')" ]
}

@test "unset removes a key so the default applies again" {
  printf '%s\n' 'gateway_port=9090' 'core_name=mgw_abc' > "$S"
  run settings 'settingsUnset "$S" gateway_port && settingsLoad "$D" "$S" && settingsGet gateway_port && ! settingsIsSet gateway_port'
  [ "$status" -eq 0 ]
  [ "$output" = "8080" ]
  [ "$(cat "$S")" = "core_name=mgw_abc" ]
}

@test "unset of the last key leaves an empty file, of a missing file nothing" {
  printf '%s\n' 'gateway_port=9090' > "$S"
  run settings 'settingsUnset "$S" gateway_port && settingsUnset "$S.missing" gateway_port'
  [ "$status" -eq 0 ]
  [ -e "$S" ] && [ ! -s "$S" ]
  [ ! -e "$S.missing" ]
}

@test "a failed write leaves the file as it was" {
  printf '%s\n' 'gateway_port=9090' > "$S"
  chmod 500 "$BATS_TEST_TMPDIR"
  run settings 'settingsSet "$S" gateway_port 1'
  chmod 700 "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [ "$(cat "$S")" = "gateway_port=9090" ]
}

@test "the shipped settings.defaults parses and every key is valid" {
  run settings 'settingsLoad "$LIB/../../settings.defaults" "" && echo "$settings_keys" && settingsGet gateway_port && settingsGet update_retry_limit'
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "core_id core_name stack_name "* ]]
  [ "${lines[1]}" = "8080" ]
  [ "${lines[2]}" = "3" ]
  # every non-comment line of the file is a setting
  [ "$(grep -cv '^\(#.*\)\?$' "$LIB/../../settings.defaults")" -eq "$(echo "${lines[0]}" | wc -w)" ]
}
