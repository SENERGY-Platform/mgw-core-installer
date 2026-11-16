#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# Locations on the host. Fixed on the supported system (Debian 13), so they are no settings. The
# tests may set them before sourcing this file, to work on temporary folders; nothing else does.

# shellcheck disable=SC2034 # used by the files sourcing this one
: "${host_systemd_path:=/etc/systemd/system}"
: "${host_logrotated_path:=/etc/logrotate.d}"
: "${host_cron_path:=/etc/cron.daily}"
: "${host_avahi_path:=/etc/avahi/services}"
: "${host_docker_socket:=/var/run/docker.sock}"
: "${host_os_release:=/etc/os-release}"

# returns 0 on the supported system, Debian 13; otherwise prints why to stderr and returns 1. For the
# checks of a new install and of a migration; an update doesn't check, so a core keeps getting fixes
# on the system it was installed on.
hostSupported() {
  host_os_id="$(sed -n 's/^ID=//p' "$host_os_release" 2> /dev/null | tr -d '"')"
  host_os_version="$(sed -n 's/^VERSION_ID=//p' "$host_os_release" 2> /dev/null | tr -d '"')"
  if [ "$host_os_id" = "debian" ] && [ "$host_os_version" = "13" ]
  then
    return 0
  fi
  host_os_name="$(sed -n 's/^PRETTY_NAME=//p' "$host_os_release" 2> /dev/null | tr -d '"')"
  echo "Debian 13 is required, this is ${host_os_name:-an unknown system}" >&2
  return 1
}

# prints the platform the host binaries are released for (the name in their release asset)
hostPlatform() {
  case "$(uname -s)" in
    Linux)
      echo linux
      ;;
    *)
      echo "unsupported platform '$(uname -s)'" >&2
      return 1
  esac
}

# prints the architecture folder in the host binaries' release archives
hostArch() {
  case "$(uname -m)" in
    x86_64)
      echo amd64
      ;;
    aarch64|armv8l)
      echo arm64
      ;;
    armv7l)
      echo arm
      ;;
    *)
      echo "unsupported architecture '$(uname -m)'" >&2
      return 1
  esac
}
