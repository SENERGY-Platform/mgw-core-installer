#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

load helpers

setup() {
  export F="$BATS_TEST_TMPDIR/update"
}

state() {
  dsh "$1" file state
}

@test "a record written and read back" {
  run state '
    recordSet u format "$state_format"
    recordSet u writer v1_3_0
    recordSet u result running
    recordSet u started 2026-11-09T03:00:00Z
    recordWrite "$F" u "$state_update_fields" warning
    recordClear r "$state_update_fields" warning
    recordLoad "$F" r warning
    echo "$r_format $r_writer $r_result $r_started [$r_finished]"'
  [ "$status" -eq 0 ]
  [ "$output" = "1 v1_3_0 running 2026-11-09T03:00:00Z []" ]
}

@test "the fields are written in their order, empty ones too, then the repeated keys" {
  run state '
    recordSet c check_result failed
    recordWarn c "first"
    recordWarn c "second"
    recordWrite "$F" c "$state_check_fields" warning'
  [ "$status" -eq 0 ]
  [ "$(cat "$F")" = "$(printf '%s\n' format= check_time= check_result=failed check_version= check_step= warnings_omitted= warning=first warning=second)" ]
  [ "$(stat -c %a "$F")" = "644" ]
}

@test "reading is tolerant" {
  printf '%s\r\n' 'result=failed' 'added_by_a_newer_version=x' '# comment' 'no separator' 'Bad=1' 'step=set a=b' 'phase=a_phase_added_later' 'result=success' > "$F"
  run state 'recordLoad "$F" r warning && echo "$r_result|$r_step|$r_phase|$r_added_by_a_newer_version|[$r_finished]"'
  [ "$status" -eq 0 ]
  [ "$output" = "success|set a=b|a_phase_added_later|x|[]" ]
}

@test "values are never executed" {
  printf '%s\n' "step=\$(touch $BATS_TEST_TMPDIR/executed)" > "$F"
  run state 'recordLoad "$F" r "" && echo "$r_step"'
  [ "$output" = "\$(touch $BATS_TEST_TMPDIR/executed)" ]
  [ ! -e "$BATS_TEST_TMPDIR/executed" ]
}

@test "repeated keys are read as a list in order" {
  printf '%s\n' 'created=volume:a' 'result=running' 'created=network:b' 'created=unit:c' > "$F"
  run state 'recordLoad "$F" i created && printf "%s\n" "$i_created"'
  [ "$output" = "$(printf '%s\n' volume:a network:b unit:c)" ]
}

@test "loading clears the repeated keys of an earlier load" {
  printf '%s\n' 'warning=old' > "$F"
  printf '%s\n' 'warning=new' > "$F.2"
  run state 'recordLoad "$F" r warning && recordLoad "$F.2" r warning && echo "$r_warning"'
  [ "$output" = "new" ]
}

@test "a missing file returns 1, an oversized one 2" {
  run state 'recordLoad "$F" r ""'
  [ "$status" -eq 1 ]
  head -c 65537 /dev/zero | tr '\0' a > "$F"
  run state 'recordLoad "$F" r ""'
  [ "$status" -eq 2 ]
  [[ "$output" == *"larger than 65536 bytes"* ]]
}

@test "a file of exactly the maximum size is read" {
  { printf 'step='; head -c $((65536 - 6)) /dev/zero | tr '\0' a; printf '\n'; } > "$F"
  run state 'recordLoad "$F" r "" && echo "${#r_step}"'
  [ "$status" -eq 0 ]
  [ "$output" = "65530" ]
}

@test "values become one line of limited length" {
  run state '
    recordSet u step "$(printf "line one\nline two\r\n")"
    recordSet u old_project "$(head -c 1500 /dev/zero | tr "\0" a)"
    echo "[$u_step]"
    echo "${#u_old_project}"'
  [ "${lines[0]}" = "[line one line two ]" ]
  [ "${lines[1]}" = "1000" ]
}

@test "warnings: at most 20 of at most 200 characters, the rest counted" {
  run state '
    i=0
    while [ $i -lt 23 ]; do recordWarn u "warning $i $(head -c 300 /dev/zero | tr "\0" w)"; i=$((i + 1)); done
    recordWrite "$F" u "warnings_omitted" warning'
  [ "$status" -eq 0 ]
  [ "$(grep -c '^warning=' "$F")" -eq 20 ]
  [ "$(grep '^warning=' "$F" | awk '{ print length($0) }' | sort -u)" = "208" ]
  grep -qx 'warnings_omitted=3' "$F"
}

@test "a warning with a line break stays one warning" {
  run state 'recordWarn u "$(printf "a\nb")" && recordWrite "$F" u "" warning'
  [ "$(cat "$F")" = "warning=a b" ]
}

@test "a record is written completely: no keys of the previous file survive" {
  printf '%s\n' 'writer=v1_2_0' 'only_the_old_version_knows=1' > "$F"
  run state 'recordSet u writer v1_3_0 && recordWrite "$F" u "writer" ""'
  [ "$(cat "$F")" = "writer=v1_3_0" ]
}

@test "save previous keeps the old record unparsed" {
  printf '%s\n' 'writer=v1_2_0' 'whatever the old version wrote' > "$F"
  run state 'recordSavePrevious "$F" "$F.previous" && recordSavePrevious "$F.missing" "$F.missing.previous"'
  [ "$status" -eq 0 ]
  cmp "$F" "$F.previous"
  [ ! -e "$F.missing.previous" ]
}

@test "the time is UTC in the record format" {
  run state 'stateNow'
  [[ "$output" =~ ^20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z$ ]]
}

@test "attempts: count failures per version, reset, limit" {
  A="$BATS_TEST_TMPDIR/attempts"
  run state "
    attemptsFailures '$A' v1_3_0
    attemptsAddFailure '$A' v1_3_0 && attemptsAddFailure '$A' v1_3_0
    attemptsFailures '$A' v1_3_0
    attemptsLimitReached '$A' v1_3_0 3 || echo below
    attemptsAddFailure '$A' v1_3_0
    attemptsLimitReached '$A' v1_3_0 3 && echo reached
    attemptsFailures '$A' v1_4_0
    attemptsAddFailure '$A' v1_4_0 && attemptsFailures '$A' v1_4_0
    attemptsReset '$A' v1_4_0 && attemptsFailures '$A' v1_4_0"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' 0 2 below reached 0 1 0)" ]
  [ "$(cat "$A")" = "$(printf '%s\n' version=v1_4_0 failures=0)" ]
}

@test "attempts: a damaged count reads as 0" {
  A="$BATS_TEST_TMPDIR/attempts"
  printf '%s\n' 'version=v1_3_0' 'failures=two' > "$A"
  run state "attemptsFailures '$A' v1_3_0"
  [ "$output" = "0" ]
}

@test "images: add once, remove, list" {
  I="$BATS_TEST_TMPDIR/images"
  run state "
    imagesList '$I'
    imagesAdd '$I' nginx:1.31.1-alpine && imagesAdd '$I' mysql:8.4.9 && imagesAdd '$I' nginx:1.31.1-alpine
    imagesRemove '$I' mysql:8.4.9 && imagesRemove '$I' not:listed
    imagesAdd '$I' 'ghcr.io/senergy-platform/mgw-gui:v3.3.0'
    imagesList '$I'"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' nginx:1.31.1-alpine ghcr.io/senergy-platform/mgw-gui:v3.3.0)" ]
}

@test "images: a name is matched exactly, not as a pattern" {
  I="$BATS_TEST_TMPDIR/images"
  printf '%s\n' 'nginx:1.31.1-alpine' 'nginx:1x31.1-alpine' > "$I"
  run state "imagesRemove '$I' nginx:1.31.1-alpine && imagesList '$I'"
  [ "$output" = "nginx:1x31.1-alpine" ]
}
