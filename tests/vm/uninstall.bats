#!/usr/bin/env bats

# Copyright (c) 2026 InfAI (CC SES)

# uninstall.sh on the test VM, against cores installed with setup.sh (GitHub mock, real images). The
# uninstall always removes the core's images; to keep them cached for the next run, stopped "keeper"
# containers use them, so docker refuses to remove them, which the uninstall reports. A separately
# tagged copy shows that unused images are removed.

load ../unit/helpers
load github

# Subnets and ports: each file has ranges of its own, so files can run in parallel (tests/vm/run.sh
# -j): core and gateway 10.<n>.0.0 and 10.<n>.1.0, module 10.<n+120>.0.0/16, with n in steps of ten
# per file (setup 20, uninstall 35, ctrl 45, update 55, update_failures 65, recover 75, version 85,
# restore 95);
# gateway ports per file in thousands from 20000. Only 10.x: docker uses 172.17.0.0/16 and up.

setup_file() {
  startGithubMock
  export REPO="$BATS_TEST_DIRNAME/../.."
  export DIR="/var/tmp/mgwt-uninstall-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  export U="u$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')" V="v$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  local n=$((RANDOM % 8 + 35))
  printf '%s\n' "install_dir=$DIR" "core_id=$U" "gateway_port=$((21000 + RANDOM % 1000))" "subnet_core=10.$n.0.0" \
    "subnet_gateway=10.$n.1.0" "subnet_module=10.$((n + 120)).0.0" autostart=true start_core=true \
    logrotate=false cron=false advertise=false > "$BATS_FILE_TMPDIR/u.conf"
  "$REPO/setup.sh" -c "$BATS_FILE_TMPDIR/u.conf" > "$BATS_FILE_TMPDIR/u.log" 2>&1
  n=$((n + 1))
  printf '%s\n' "install_dir=$DIR" "core_id=$V" "gateway_port=$((21000 + RANDOM % 1000))" "subnet_core=10.$n.0.0" \
    "subnet_gateway=10.$n.1.0" "subnet_module=10.$((n + 120)).0.0" autostart=false start_core=false \
    logrotate=false cron=false advertise=false > "$BATS_FILE_TMPDIR/v.conf"
  "$REPO/setup.sh" -c "$BATS_FILE_TMPDIR/v.conf" > "$BATS_FILE_TMPDIR/v.log" 2>&1
  # keepers for the core images, a module of core U, an image only core U lists
  local image i=0
  for image in $(cat "$DIR/$U/state/images"); do
    # a tmpfs on every path the image declares as a volume, so the keeper gets no anonymous volumes
    # (they would disturb the volume counts of test files running in parallel)
    docker create --name "mgwt-keep-$U-$i" $(docker image inspect -f '{{range $p, $_ := .Config.Volumes}}--tmpfs {{$p}} {{end}}' "$image") "$image" > /dev/null 2>&1
    i=$((i + 1))
  done
  docker tag busybox:1.37 "mgwtest/$U-core:1"
  echo "mgwtest/$U-core:1" >> "$DIR/$U/state/images"
  docker tag busybox:1.37 "mgwtest/$U-module:1"
  docker volume create --label "mgw_cid=$U" "dep-$U-data" > /dev/null
  docker create --name "mgwt-module-$U" --label "mgw_cid=$U" -v "dep-$U-data:/data" "mgwtest/$U-module:1" true > /dev/null
  # after the keepers, which get anonymous volumes of their own (mysql and kratos declare volumes)
  docker volume ls -q --filter label=com.docker.volume.anonymous | sort > "$BATS_FILE_TMPDIR/anonymous"
}

teardown_file() {
  stopGithubMock
  docker ps -aq --filter "name=mgwt-keep-$U-" | xargs -r docker rm -f -v > /dev/null
  docker rm -f "mgwt-module-$U" > /dev/null 2>&1 || true
  docker volume rm "dep-$U-data" > /dev/null 2>&1 || true
  docker image rm "mgwtest/$U-core:1" "mgwtest/$U-module:1" > /dev/null 2>&1 || true
  local root
  for root in "$DIR"/*; do
    [ -d "$root/state" ] || continue
    rm -f "$root/state/images"
    "$root/current/uninstall.sh" -y > /dev/null 2>&1 || "$REPO/assets/scripts/uninstall.sh" -path="$root" -y > /dev/null 2>&1 || true
  done
  rm -rf "$DIR"
}

@test "both cores are installed" {
  cat "$BATS_FILE_TMPDIR/u.log" "$BATS_FILE_TMPDIR/v.log" | grep -i "successful\|fail\|error" || true
  grep -qx result=success "$DIR/$U/state/install"
  grep -qx result=success "$DIR/$V/state/install"
}

@test "answering n removes nothing" {
  run sh -c "echo n | '$DIR/$U/current/uninstall.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"core id:   $U"* ]] && [[ "$output" == *"nothing removed"* ]]
  [ -d "$DIR/$U/current" ]
}

@test "a held lock refuses the uninstall" {
  exec 7<> "$DIR/$U/state/lock"
  flock 7
  run "$DIR/$U/current/uninstall.sh" -y
  exec 7>&-
  [ "$status" -eq 1 ]
  [[ "$output" == *"try again later"* ]]
  [ -d "$DIR/$U/current" ]
}

@test "uninstall removes everything of the core, modules included" {
  local mount_unit
  mount_unit="$(systemd-escape --path --suffix=mount "/mnt/mgw_$U/secrets")"
  run "$DIR/$U/current/uninstall.sh" -y
  echo "$output"
  # the kept images are reported, nothing else
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | grep -c 'could not remove')" -eq "$(echo "$output" | grep -c 'could not remove: image .* (still used by another container)')" ]
  [ ! -e "$DIR/$U" ] && [ ! -e "/mnt/mgw_$U" ]
  ! findmnt -n "/mnt/mgw_$U/secrets" > /dev/null
  [ -z "$(find /etc/systemd/system -name "mgw_$U-*" -o -name "$mount_unit")" ]
  [ -z "$(systemctl list-units --all --no-legend "mgw_$U-*")" ]
  [ -z "$(docker ps -aq --filter "label=mgw_cid=$U")" ]
  [ -z "$(docker volume ls -q --filter "label=mgw_cid=$U")" ]
  [ -z "$(docker volume ls -q | grep "^mgw_${U}_")" ]
  [ -z "$(docker network ls --format '{{.Name}}' | grep "^mgw_$U-")" ]
  ! docker image inspect "mgwtest/$U-core:1" > /dev/null 2>&1
  ! docker image inspect "mgwtest/$U-module:1" > /dev/null 2>&1
  # the other core is untouched
  grep -qx result=success "$DIR/$V/state/install"
  [ -n "$(docker ps -aq --filter "label=mgw_cid=$V")" ]
}

@test "a broken core is removed from an archive with -path" {
  rm "$DIR/$V/current"
  run "$REPO/assets/scripts/uninstall.sh" -path="$DIR/$V" -y
  echo "$output"
  [ ! -e "$DIR/$V" ] && [ ! -e "/mnt/mgw_$V" ]
  [ -z "$(docker ps -aq --filter "label=mgw_cid=$V")" ]
  [ -z "$(docker volume ls -q | grep "^mgw_${V}_")" ]
  [ -z "$(docker network ls --format '{{.Name}}' | grep "^mgw_$V-")" ]
  # with both cores gone, no anonymous volumes of their containers are left
  [ "$(docker volume ls -q --filter label=com.docker.volume.anonymous | sort)" = "$(cat "$BATS_FILE_TMPDIR/anonymous")" ]
}

@test "without a core there is nothing to remove" {
  run "$REPO/assets/scripts/uninstall.sh" -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"no core found"* ]]
  run "$REPO/assets/scripts/uninstall.sh" -path=/var/tmp -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no state/settings"* ]]
}
