#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

load helpers

export DEFAULTS="$BATS_TEST_DIRNAME/../../assets/settings.defaults"

setup_lib() {
  dsh 'settingsLoad "$DEFAULTS" "" || exit 9; '"$1" file settings state lock setup
}

conf() {
  printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/setup.conf"
}

@test "config file: settings and the install's own keys, values taken literally" {
  conf '# a comment' '' 'install_dir=/srv/mgw' 'gateway_port=9090' 'start_core=true' 'core_usr=admin user'
  run setup_lib 'configLoad "$BATS_TEST_TMPDIR/setup.conf" && setupGet install_dir && setupGet gateway_port && setupGet start_core && setupGet core_usr && setupGet subnet_core'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' /srv/mgw 9090 true 'admin user' 10.0.0.0)" ]
}

@test "config file: unknown keys fail with their line, old config files are recognised" {
  conf 'gateway_port=8080' 'base_path=/opt/mgw' 'skip_pgk_install_confirm="true"' 'cron="true" # auto updates'
  run setup_lib 'configLoad "$BATS_TEST_TMPDIR/setup.conf"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 2: not a known setting: 'base_path=/opt/mgw'"* ]]
  [[ "$output" == *"line 3: not a known setting"* ]]
  [[ "$output" == *"has the format of the settings"* ]]
  # a known key with a quoted value is read, and its validation explains the format
  run setup_lib 'configLoad "$BATS_TEST_TMPDIR/setup.conf" 2> /dev/null; setupValidate cron "$(setupGet cron)"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid cron '\"true\" # auto updates': true or false (the config file takes values without quotes)"* ]]
}

@test "config file: a line that isn't key=value fails" {
  conf 'gateway_port 8080'
  run setup_lib 'configLoad "$BATS_TEST_TMPDIR/setup.conf"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 1"* ]]
}

@test "the shipped example config file is valid" {
  run setup_lib 'configLoad "${DEFAULTS%/*}/setup.conf.example" && setupValidateAll'
  [ "$status" -eq 0 ]
}

@test "get: set values, defaults, empty for the install's own keys" {
  run setup_lib 'setupSet gateway_port 1; echo "[$(setupGet gateway_port)][$(setupGet allow_beta)][$(setupGet install_dir)]"'
  [ "$output" = "[1][false][]" ]
}

@test "ipv4 addresses" {
  run setup_lib 'ipv4Int 10.0.0.0; ipv4Int 255.255.255.255; ipv4Int 1.2.3.4'
  [ "$output" = "$(printf '%s\n' 167772160 4294967295 16909060)" ]
  for bad in "" 1.2.3 1.2.3.4.5 256.0.0.0 1..2.3 .1.2.3 1.2.3. a.b.c.d 1.2.3.4/28 0001.2.3.4; do
    run setup_lib 'ipv4Int "'"$bad"'"'
    [ "$status" -eq 1 ] || { echo "accepted '$bad'"; false; }
  done
}

@test "subnets: aligned to their prefix, overlap" {
  run setup_lib 'subnetValid 10.0.0.0 28 && subnetValid 10.0.0.16 28 && subnetValid 10.1.0.0 16 && ! subnetValid 10.0.0.5 28 && ! subnetValid 10.1.1.0 16'
  [ "$status" -eq 0 ]
  run setup_lib 'subnetsOverlap 10.0.0.0/28 10.0.0.8/29 && subnetsOverlap 10.1.0.0/16 10.1.200.0/28 && ! subnetsOverlap 10.0.0.0/28 10.0.0.16/28 && ! subnetsOverlap 10.0.0.0/28 10.1.0.0/16'
  [ "$status" -eq 0 ]
}

@test "validation of single values" {
  valid=(core_id=ab12 core_id=a-b_c core_name=mgw_ab12 install_dir=/opt/mgw install_dir=/srv/mgw-2/x
    gateway_port=1 gateway_port=65535 subnet_core=10.0.0.16 subnet_module=172.20.0.0 core_db_pw=abcdefgh core_usr_pw=A.b_c~d+e-f
    core_usr=core-user systemd=false start_core=true)
  for kv in "${valid[@]}"; do
    run setup_lib 'setupValidate "'"${kv%%=*}"'" "'"${kv#*=}"'"'
    [ "$status" -eq 0 ] || { echo "refused $kv: $output"; false; }
  done
  invalid=(core_id= core_id=Ab core_id=-a "core_id=a b" core_id=a.b install_dir=relative install_dir=/ "install_dir=/a b"
    install_dir=/a/../b gateway_port=0 gateway_port=65536 gateway_port=80a gateway_port=08080 subnet_core=10.0.0.5 subnet_core=10.0.0
    subnet_module=10.1.1.0 core_db_pw=short 'core_db_pw=with$dollar' 'core_usr_pw=with space1' core_usr= systemd=yes)
  for kv in "${invalid[@]}"; do
    run setup_lib 'setupValidate "'"${kv%%=*}"'" "'"${kv#*=}"'"'
    [ "$status" -eq 1 ] || { echo "accepted $kv"; false; }
  done
}

@test "a refused password isn't printed" {
  run setup_lib 'setupValidate core_db_pw "sec\$ret12"'
  [ "$status" -eq 1 ]
  [[ "$output" != *"sec"* ]]
}

@test "all values: overlapping subnets and a stack name other than the core name" {
  run setup_lib 'setupSet subnet_core 10.1.0.0; setupSet core_name mgw_a; setupSet stack_name mgw; setupValidateAll'
  [ "$status" -eq 1 ]
  [[ "$output" == *"subnets overlap"* ]]
  [[ "$output" == *"stack_name must equal core_name"* ]]
  run setup_lib 'setupSet core_name mgw_a; setupSet stack_name mgw_a; setupValidateAll'
  [ "$status" -eq 0 ]
}

@test "unfinished installs: not success and not locked" {
  local d="$BATS_TEST_TMPDIR/install"
  mkdir -p "$d/done/state" "$d/killed/state" "$d/failed/state" "$d/no_record/state" "$d/running/state"
  printf 'result=success\n' > "$d/done/state/install"
  printf 'result=running\n' > "$d/killed/state/install"
  printf 'result=failed\n' > "$d/failed/state/install"
  printf 'result=running\n' > "$d/running/state/install"
  touch "$d/running/state/lock"
  exec 7<> "$d/running/state/lock"
  flock 7
  run setup_lib 'setupUnfinished "'"$d"'"'
  exec 7>&-
  [ "$output" = "$(printf '%s\n' "$d/failed" "$d/killed")" ]
}

@test "missing packages" {
  run setup_lib 'setupMissingPkg "sh: coreutils:ls definitely-missing-pkg: gettext-base:no-such-command-x"'
  [ "$output" = "definitely-missing-pkg gettext-base" ]
}
