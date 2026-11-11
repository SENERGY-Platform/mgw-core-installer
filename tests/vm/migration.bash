# Copyright (c) 2026 InfAI (CC SES)

# Shared by the migration test files (migration*.bats): a real old release installed from its GitHub
# archive, migrated to a test release v0.40.0 through the real old stage one (<install dir>/update.sh)
# (PLAN.md 15, m7-migration.md). The old lib/github.sh is pointed at the GitHub mock before the old
# setup.sh runs, so the old installer fetches its binaries and the test releases from the mock, and
# the old update.sh and setup.sh at work folders of the test file's own (/tmp/mgw-update-<name>
# instead of /tmp/mgw-update, /tmp/mgw-update-<name>-install instead of /tmp/mgw-install), so the
# files can run in parallel. Everything else of the old code runs unchanged
# (m7-migration.md, finding 5).

OLD_VERSION=v0.31.1

# starts the mock, builds the test release and installs the old release OLD_VERSION; call in
# setup_file. $1 names the file (install dir, work folder), $2 is its subnet base n (10.<n>.0.0,
# module 10.<n+120>.0.0), $3 its port base, $4 the old systemd setting (default true).
migrationSetupFile() {
  export REPO="$BATS_TEST_DIRNAME/../.."
  export MGW_TEST_RELEASES="$BATS_FILE_TMPDIR/releases"
  startGithubMock
  export DIR="/var/tmp/mgwt-$1-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  export S="m$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  export WORK="/tmp/mgw-update-$1" MIG_N="$2" MIG_PORT="$3"
  "$REPO/tests/vm/build_release.sh" v0.40.0 "$MGW_TEST_RELEASES"
  installOld "$OLD_VERSION" "${4:-true}"
}

# call in teardown_file
migrationTeardownFile() {
  stopGithubMock
  removeInstallation
}

# prints the archive of the old release $1, downloaded once into the test cache
oldArchive() {
  local f="$MGW_TEST_CACHE/old/mgw_core_installer_$1.tar.gz"
  if [ ! -s "$f" ]; then
    mkdir -p "${f%/*}"
    curl -fsSL -o "$f.tmp.$$" "https://github.com/SENERGY-Platform/mgw-core-installer/releases/download/$1/mgw_core_installer_$1.tar.gz"
    mv "$f.tmp.$$" "$f"
  fi
  echo "$f"
}

# installs the old release $1 into $DIR with the old setup.sh and starts it. $2 is the old systemd
# setting (default true); without systemd the old ctrl.sh starts the core, as the old setup.sh leaves
# that to it.
installOld() {
  local x="$BATS_FILE_TMPDIR/old-$1" n=$((RANDOM % 3 + MIG_N)) sd="${2:-true}"
  rm -rf "$x"
  mkdir -p "$x"
  tar -xzf "$(oldArchive "$1")" -C "$x"
  sed -i "s|https://api.github.com|$MGW_TEST_GITHUB_API|" "$x/assets/scripts/lib/github.sh"
  sed -i "s|^wrk_spc=\"/tmp/mgw-update\"|wrk_spc=\"$WORK\"|" "$x/assets/scripts/update.sh"
  grep -qx "wrk_spc=\"$WORK\"" "$x/assets/scripts/update.sh"
  # the old setup.sh's own work folder, also fixed (/tmp/mgw-install)
  sed -i "s|wrk_spc=\"/tmp/mgw-install\"|wrk_spc=\"$WORK-install\"|" "$x/setup.sh"
  grep -q "wrk_spc=\"$WORK-install\"" "$x/setup.sh"
  # the old config file is sourced shell code; logrotate on, so a file in /etc is moved aside
  printf '%s\n' "base_path=$DIR" "core_id=$S" "gateway_port=$((MIG_PORT + RANDOM % 1000))" "subnet_core=10.$n.0.0" \
    "subnet_gateway=10.$n.1.0" "subnet_module=10.$((n + 120)).0.0" "systemd=$sd" logrotate=true cron=false \
    advertise=false allow_beta=false skip_pgk_install_confirm=true start_core=true > "$BATS_FILE_TMPDIR/old.conf"
  "$x/setup.sh" -c "$BATS_FILE_TMPDIR/old.conf" > "$BATS_FILE_TMPDIR/old-setup.log" 2>&1 || { tail -n 30 "$BATS_FILE_TMPDIR/old-setup.log" >&3; return 1; }
  if [ "$sd" != "true" ]; then
    "$DIR/ctrl.sh" start > "$BATS_FILE_TMPDIR/old-start.log" 2>&1 || { tail -n 30 "$BATS_FILE_TMPDIR/old-start.log" >&3; return 1; }
  fi
}

# replaces whatever is installed in $DIR with a fresh old installation of the release $1 ($2: systemd)
reinstallOld() {
  removeInstallation
  installOld "$@"
}

# removes whatever is installed in $DIR: the new layout with its uninstall.sh, the old one with the old
# uninstall.sh
removeInstallation() {
  # old containers left by a test that ended between the layouts
  docker ps -aq --filter "label=com.docker.compose.project=mgw_$S" | xargs -r docker rm -f > /dev/null
  if [ -e "$DIR/current" ]; then
    rm -f "$DIR/state/images"
    "$REPO/assets/scripts/uninstall.sh" -path="$DIR" -y > /dev/null 2>&1 || true
  elif [ -x "$DIR/uninstall.sh" ]; then
    "$DIR/uninstall.sh" -path="$DIR" -y > /dev/null 2>&1 || true
  fi
  umount "/mnt/mgw_$S/secrets" 2> /dev/null || true
  rm -rf "$DIR" "/mnt/mgw_$S" "$WORK" "$WORK-install"
}

# returns 0 if the old core runs: its core-manager (unit or process) and its containers
oldRunning() {
  if grep -q "^systemd=true" "$DIR/.settings"; then
    systemctl is-active --quiet "mgw_$S-core-manager.service" || return 1
    [ -f "/etc/systemd/system/mgw_$S-core-manager.service" ] && [ ! -L "/etc/systemd/system/mgw_$S-core-manager.service" ] || return 1
  else
    pgrep -f "^$DIR/bin/SENERGY-Platform/mgw-core-manager/bin" > /dev/null || return 1
  fi
  local i=0
  while [ $i -lt 30 ]; do
    [ "$(docker ps -q --filter "name=^mgw_$S-nginx\$" --filter status=running)" != "" ] && return 0
    sleep 2
    i=$((i + 1))
  done
  return 1
}

# returns 0 if the migration left nothing of the new layout but state/update and state/lock
nothingNew() {
  [ ! -e "$DIR/current" ] && [ ! -e "$DIR/v0_40_0" ] && [ ! -e "$DIR/v0_40_0_tmp" ] && [ ! -e "$DIR/state/settings" ]
}

# prints the field $1 of the old .update_status
oldStatus() {
  jq -r ".$1" "$DIR/.update_status"
}

# returns 0 if the old installation is back as before a rolled back migration: nothing new, the old
# files in /etc in place, the old core running
rolledBack() {
  grep -qx result=failed "$DIR/state/update" && grep -qx rolled_back=true "$DIR/state/update"
  nothingNew
  [ ! -e "$DIR/state/migration" ] && [ ! -e "$DIR/state/host-manager" ]
  [ ! -e "/etc/systemd/system/mgw_$S-recover.service" ]
  [ -f "/etc/logrotate.d/mgw_${S}_core" ] && [ ! -L "/etc/logrotate.d/mgw_${S}_core" ]
  # the old mount unit is the old file again, enabled
  if grep -q "^systemd=true" "$DIR/.settings"; then
    local mount_unit
    mount_unit="$(systemd-escape --path --suffix=mount "/mnt/mgw_$S/secrets")"
    [ -f "/etc/systemd/system/$mount_unit" ] && ! grep -q "^Description=" "/etc/systemd/system/$mount_unit"
    systemctl is-enabled --quiet "$mount_unit"
  fi
  [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=mgw_${S}_v0_40_0")" ]
  [ "$(oldStatus result)" = "failed" ] && [[ "$(oldStatus step)" == *"(rolled back)"* ]]
  oldRunning
}

# waits until the new core runs: its core-manager has started the 7 long-running containers
newRunning() {
  local i=0 n
  while [ $i -lt 60 ]; do
    n="$(docker ps --filter "label=com.docker.compose.project=mgw_${S}_v0_40_0" --filter status=running --format '{{.Label "core_srv_oneshot"}}' | grep -c '^$' || true)"
    [ "$n" -eq 7 ] && return 0
    sleep 5
    i=$((i + 1))
  done
  docker ps -a --filter "label=com.docker.compose.project=mgw_${S}_v0_40_0" --format '{{.Names}} {{.Status}}'
  return 1
}

# returns 0 if the migration succeeded and the old installation is gone
migrated() {
  grep -qx result=success "$DIR/state/update" && grep -qx kind=migration "$DIR/state/update"
  # an old image may still be in use by another test file's old core running in parallel; anything
  # else the cleanup leaves is a failure
  if ! grep -qx step=done "$DIR/state/update"; then
    grep -qx "step=done, the cleanup left something behind" "$DIR/state/update"
    ! grep '^warning=' "$DIR/state/update" | grep -v '^warning=cleanup: image .* still in use, not removed$'
  fi
  [ "$(readlink "$DIR/current")" = "v0_40_0" ] && [ ! -e "$DIR/v0_40_0_tmp" ]
  local f
  for f in bin container scripts ctrl.sh update.sh uninstall.sh .options .version .binaries .units .settings .pid \
    .update_status state/migration; do
    [ ! -e "$DIR/$f" ] || { echo "$f left"; return 1; }
  done
  [ ! -e "$WORK" ]
  [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=mgw_$S")" ]
  grep -qx "core_id=$S" "$DIR/state/settings" && grep -qx "stack_name=mgw_$S" "$DIR/state/settings"
  [ "$(stat -c %a "$DIR/state/settings")" = "600" ]
}
