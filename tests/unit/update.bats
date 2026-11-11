#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

load helpers

setup() {
  export R="$BATS_TEST_TMPDIR/releases.json" C="$BATS_TEST_TMPDIR/check"
  cat > "$R" <<'JSON'
[
  {"tag_name": "v0.42.0-beta1", "prerelease": true, "draft": false},
  {"tag_name": "v0.41.1", "prerelease": false, "draft": false},
  {"tag_name": "v0.50.0", "prerelease": false, "draft": true},
  {"tag_name": "v0.41.2-beta1", "prerelease": false, "draft": false},
  {"tag_name": "not-a-version", "prerelease": false, "draft": false},
  {"tag_name": "v0.40.0", "prerelease": false, "draft": false},
  {"tag_name": "v0.41.0", "prerelease": false, "draft": false}
]
JSON
}

update_lib() {
  dsh "$1" file state semver update
}

@test "the newest release newer than the current version" {
  run update_lib 'updatePickRelease "$R" v0.40.0 false'
  [ "$output" = "v0.41.1" ]
}

@test "pre-releases only with allow_beta, also tags marked wrongly" {
  run update_lib 'updatePickRelease "$R" v0.40.0 true'
  [ "$output" = "v0.42.0-beta1" ]
  run update_lib 'updatePickRelease "$R" v0.41.1 false'
  [ "$output" = "" ]
}

@test "drafts and tags that aren't versions never count" {
  run update_lib 'updatePickRelease "$R" v0.42.0 true'
  [ "$output" = "" ]
}

@test "nothing newer: nothing" {
  run update_lib 'updatePickRelease "$R" v0.41.1 false'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  run update_lib 'updatePickRelease "$R" v1.0.0 true'
  [ "$output" = "" ]
}

@test "a beta core moves to the release" {
  run update_lib 'updatePickRelease "$R" v0.41.1-beta3 false'
  [ "$output" = "v0.41.1" ]
}

@test "an empty release list" {
  echo '[]' > "$R"
  run update_lib 'updatePickRelease "$R" v0.40.0 true'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "the check record" {
  run update_lib 'updateCheckRecord "$C" failed v0.41.1 "downloading release v0.41.1" "could not delete /tmp/mgw_abc"'
  [ "$status" -eq 0 ]
  grep -qx check_result=failed "$C"
  grep -qx check_version=v0.41.1 "$C"
  grep -qx "check_step=downloading release v0.41.1" "$C"
  grep -qx "warning=could not delete /tmp/mgw_abc" "$C"
  grep -q '^check_time=20' "$C"
  run update_lib 'updateCheckRecord "$C" up_to_date "" ""'
  ! grep -q '^warning=' "$C"
}

@test "SemVer pre-release tags count as pre-releases, other pre-release names never count" {
  cat > "$R" <<'JSON'
[
  {"tag_name": "v0.0.0-test.1", "prerelease": true, "draft": false},
  {"tag_name": "v0.42.0-test.3", "prerelease": false, "draft": false},
  {"tag_name": "v0.41.0-beta.2", "prerelease": false, "draft": false},
  {"tag_name": "v0.41.0-beta1", "prerelease": false, "draft": false},
  {"tag_name": "v0.40.0", "prerelease": false, "draft": false}
]
JSON
  run update_lib 'updatePickRelease "$R" v0.33.0-beta2 false'
  [ "$output" = "v0.40.0" ]
  run update_lib 'updatePickRelease "$R" v0.40.0 true'
  [ "$output" = "v0.41.0-beta.2" ]
}
