#!/bin/sh

# not every package a release names is needed by every install: a core without
# startup integration never calls systemctl, and the logrotate config, the cron
# job and the avahi service are only written when their setting is on - a
# cron.daily file being useless without a cron daemon to run it. those packages
# therefore sit in their own lists in .options and are appended here from the
# setting that makes them necessary, which is why both callers have to resolve
# their settings before asking for a list
getRequiredPkg() {
  pkg="$require_pkg"
  if [ "$systemd" = "true" ]
  then
    pkg="$pkg $require_pkg_systemd"
  fi
  echo "$pkg"
}

getInstallPkg() {
  pkg="$install_pkg"
  if [ "$logrotate" = "true" ]
  then
    pkg="$pkg $install_pkg_logrotate"
  fi
  if [ "$cron" = "true" ]
  then
    pkg="$pkg $install_pkg_cron"
  fi
  if [ "$advertise" = "true" ]
  then
    pkg="$pkg $install_pkg_advertise"
  fi
  echo "$pkg"
}

getMissingPkg() {
  missing=""
  for item in ${1}
  do
    pkg="${item%%:*}"
    cmd="${item##*:}"
    if [ "$cmd" = "" ]
    then
      cmd="$pkg"
    fi
    if ! command -v "$cmd" > /dev/null 2>& 1
    then
      if [ "$missing" = "" ]; then
        missing="${missing}$pkg"
      else
        missing="${missing} $pkg"
      fi
    fi
  done
  echo "$missing"
}

installPkg() {
  if ! apt-get update
  then
    return 1
  fi
  if ! apt-get install -y $1
  then
    return 1
  fi
}
