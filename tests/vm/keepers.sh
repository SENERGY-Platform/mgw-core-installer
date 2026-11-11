#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# Keeps the core images of assets/options on the VM during a test run: a stopped container per image,
# so docker refuses to remove them. Tests that remove images (an update's cleanup, the uninstall) would
# otherwise remove an image another test file, running in parallel, has just pulled and is about to
# create containers from. The images also stay cached for the next run.
#
#   tests/vm/keepers.sh create|remove      (as root on the VM, run by tests/vm/run.sh)
#
# Each keeper gets a tmpfs on every path its image declares as a volume, so it creates no anonymous
# volumes.

options="$(dirname "$0")/../../assets/options"
case "$1" in
  create)
    # shellcheck disable=SC1090
    . "$options"
    i=0
    # shellcheck disable=SC2154 # images comes from options
    for item in $images
    do
      image="${item#*=}"
      docker image inspect "$image" > /dev/null 2>&1 || docker pull -q "$image" > /dev/null || continue
      # shellcheck disable=SC2046 # one --tmpfs argument per declared volume
      docker create --name "mgwt-keep-run-$i" $(docker image inspect -f '{{range $p, $_ := .Config.Volumes}}--tmpfs {{$p}} {{end}}' "$image") \
        "$image" > /dev/null 2>&1
      i=$((i + 1))
    done
    ;;
  remove)
    docker ps -aq --filter "name=mgwt-keep-run-" | xargs -r docker rm -f -v > /dev/null
    ;;
  *)
    echo "usage: $0 create|remove" >&2
    exit 1
esac
