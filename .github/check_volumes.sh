#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# Fails if a core image declares a volume the compose file doesn't mount (implementation.md M8,
# m8-release.md finding 5):
#
#   .github/check_volumes.sh [<assets folder> [<exceptions file>]]
#
# The defaults are this repository's assets and .github/volume-exceptions; the tests pass others.
#
# A path an image declares (VOLUME in its Dockerfile) but the compose file doesn't mount gets an
# anonymous volume. Its data is lost whenever the next version's containers are created, which every
# update does. The release workflow runs this before it publishes, the VM tests run it too
# (tests/vm/volumes.bats).
#
# - the compose file is rendered the way the installer does (lib/render.sh), with dummy values for
#   the settings the install generates
# - every service's image and mount targets come from docker compose config
# - the declared volumes come from the registry (docker buildx imagetools inspect, no pull); for a
#   multi-platform image, those of every platform
# - exceptions: one per line in the exceptions file,
#   "<service> <path> <reason>", the reason mandatory; for a path whose content really doesn't matter
#
# Doesn't catch paths an image writes to without declaring them. Needs docker with compose and buildx,
# jq, envsubst.

repo="$(cd "$(dirname "$0")/.." && pwd)"
assets="$(cd "${1:-$repo/assets}" && pwd)" || exit 1
exceptions="${2:-$repo/.github/volume-exceptions}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

lib="$assets/scripts/lib"
for check_lib in file settings state host render
do
  # shellcheck disable=SC1090
  . "$lib/$check_lib.sh" || exit 1
done

# a version folder with this repository's assets, rendered with dummy values for what the install
# generates; nothing of it is used beyond the compose file
root="$work/root"
mkdir -p "$root/v0_0_0" || exit 1
ln -s "$assets" "$root/v0_0_0/assets" || exit 1
printf '%s\n' core_id=check core_name=mgw_check stack_name=mgw_check "host_dir_repository_path=$root/repositories/host_dir" \
  core_usr_pw=dummydummy core_db_pw=dummydummy core_db_root_pw=dummydummy > "$work/settings"
settingsLoad "$assets/settings.defaults" "$work/settings" || exit 1
# shellcheck disable=SC1090,SC1091 # the version's own static asset
. "$assets/options" || exit 1
renderVersion "$root/v0_0_0" "$root" v0.0.0 v0_0_0 || exit 1

# one line per service: <service> <image> <mount target>...
if ! docker compose -f "$root/v0_0_0/config/container/docker-compose.yml" config --format json > "$work/compose.json"
then
  echo "docker compose config failed" >&2
  exit 1
fi
jq -r '.services | to_entries[] | [.key, .value.image] + [.value.volumes[]?.target] | join(" ")' "$work/compose.json" > "$work/services" || exit 1

# the exceptions, checked for a reason
if [ -e "$exceptions" ]
then
  check_n=0
  while IFS= read -r check_line || [ -n "$check_line" ]
  do
    check_n=$((check_n + 1))
    case "$check_line" in
      ""|"#"*)
        continue
    esac
    # shellcheck disable=SC2086 # split into service, path, reason
    set -- $check_line
    if [ $# -lt 3 ]
    then
      echo "$exceptions, line $check_n: '<service> <path> <reason>' expected, the reason is mandatory" >&2
      exit 1
    fi
    echo "$1 $2" >> "$work/exceptions"
  done < "$exceptions"
fi
touch "$work/exceptions"

check_rc=0
while read -r check_service check_image check_targets
do
  # the declared volumes of every platform of the image
  if ! check_declared="$(docker buildx imagetools inspect --format '{{json .Image}}' "$check_image" |
    jq -r 'if has("config") then [.] else [.[]] end | map(.config.Volumes // {} | keys[]) | unique[]')"
  then
    echo "service $check_service: cannot read the image $check_image from its registry" >&2
    check_rc=1
    continue
  fi
  for check_path in ${check_declared}
  do
    check_mounted=false
    for check_target in ${check_targets}
    do
      if [ "${check_target%/}" = "${check_path%/}" ]
      then
        check_mounted=true
      fi
    done
    if [ "$check_mounted" = "true" ] || grep -qxF -- "$check_service $check_path" "$work/exceptions"
    then
      continue
    fi
    echo "service $check_service: image $check_image declares $check_path, which the compose file doesn't mount" >&2
    check_rc=1
  done
done < "$work/services"

if [ $check_rc -eq 0 ]
then
  echo "every volume the core images declare is mounted"
fi
exit $check_rc
