#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# The recovery entry point (PLAN.md 14): run by the recovery unit at boot
# (<core_name>-recover.service, through current) and by ctrl.sh before every command. Internal, not a
# user command.
#
# - The lock tells whether a writer is alive. If someone else holds it, that holder is alive and
#   responsible; nothing to do here (m2-assets-lib.md, finding 11).
# - An install that didn't record success was killed: it is cleaned up with its own list, and
#   nothing may start (exit 1, so the service units requiring the recovery unit don't start).
# - Interrupted updates are handled from M5 on.
#
# Exit codes: 0 nothing (more) to recover, 1 failed or an unfinished install was removed.

# the libraries' variables are used across files, which shellcheck can't follow
# shellcheck disable=SC2034,SC2154

# the core root: this script is <core root>/<version folder>/assets/scripts/recover.sh, usually
# reached through current
if ! cd "${0%/*}/../../.."
then
  exit 1
fi
core_root="$(pwd)"
lib="$core_root/current/assets/scripts/lib"
if ! [ -d "$lib" ]
then
  lib="${0%/*}/lib"
fi
for recover_lib in file settings state lock host objects
do
  # shellcheck disable=SC1090
  . "$lib/$recover_lib.sh" || exit 1
done

lockAcquire "$core_root/state/lock" recover
case $? in
  0)
    ;;
  2)
    echo "the lock is held, its holder is responsible; nothing to recover"
    exit 0
    ;;
  *)
    exit 1
esac

record="$core_root/state/install"
recordClear recover_inst "result" ""
if recordLoad "$record" recover_inst "" && [ "$recover_inst_result" != "success" ]
then
  echo "unfinished install found (result '$recover_inst_result'), removing it ..." >&2
  if [ -r "$core_root/current/assets/settings.defaults" ]
  then
    settingsLoad "$core_root/current/assets/settings.defaults" "$core_root/state/settings" 2> /dev/null
  fi
  if installCleanup "$core_root" "$record"
  then
    echo "the unfinished install was removed; run setup.sh again" >&2
  else
    echo "removing the unfinished install left something behind, listed in $record" >&2
  fi
  lockRelease 2> /dev/null
  exit 1
fi

lockRelease
exit 0
