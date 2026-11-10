#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# Locations on the host. Fixed on the supported systems (Debian, Ubuntu), so they are no settings. The
# tests may set them before sourcing this file, to work on temporary folders; nothing else does.

# shellcheck disable=SC2034 # used by the files sourcing this one
: "${host_systemd_path:=/etc/systemd/system}"
: "${host_logrotated_path:=/etc/logrotate.d}"
: "${host_cron_path:=/etc/cron.daily}"
: "${host_avahi_path:=/etc/avahi/services}"
: "${host_docker_socket:=/var/run/docker.sock}"

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
