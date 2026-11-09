#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# The core's lock (PLAN.md 8): state/lock, held with flock on file descriptor 9. One holder at a
# time: update.sh, ctrl.sh, setup.sh, restore.sh, uninstall.sh. The kernel releases the lock when the
# holder's last descriptor closes, so a killed or crashed holder leaves no lock behind, only its
# entry in the file.
#
# - Nobody empties the file by opening it: it is opened with <> (read/write, no truncation).
# - After acquiring, the holder writes holder, pid and since into the file, in place: the lock
#   belongs to the inode, so the file is never replaced by a rename.
# - The content outlives the lock. Readers check whether the lock is actually held (lockHeld).
# - Taking the lock waits at most two seconds, then gives up: whoever only checks the lock holds it
#   shared for a moment, which a refusal without waiting would trip over (m1-core-manager.md,
#   finding 5).
# - Stage two of an update inherits descriptor 9 from stage one and confirms it (lockInherited)
#   instead of taking the lock again, which would wait for its own parent.
# - Everything started for good while the lock is held (the host binaries) must close descriptor 9,
#   or it would hold the lock for as long as it runs.
#
# Needs lib/file.sh and lib/state.sh.

# seconds to wait for a held lock
lock_wait=2

# takes the lock file $1 for the holder named $2 (e.g. update, ctrl.sh). Returns 0 when held, 2 if
# someone else holds it (reported on stderr), 1 on any other failure.
lockAcquire() {
  if ! command -v flock > /dev/null 2>&1
  then
    echo "flock not found" >&2
    return 1
  fi
  # a failed redirection of exec ends a non-interactive shell, so try it in a subshell first
  if ! (: 9<> "$1") 2> /dev/null
  then
    echo "cannot open lock file '$1'" >&2
    return 1
  fi
  exec 9<> "$1"
  if ! flock -w "$lock_wait" 9
  then
    exec 9>&-
    echo "$(lockDescribe "$1"), giving up" >&2
    return 2
  fi
  lockWriteHolder "$1" "$2" "$$"
  MGW_LOCK_HELD="$1"
  export MGW_LOCK_HELD
}

# confirms that this process inherited the lock on the file $1 on descriptor 9 from its parent (stage
# two from stage one) and records the holder $2 with this process's pid. Returns 0 if so, 1 if not:
# then the caller takes the lock itself.
lockInherited() {
  if [ "$MGW_LOCK_HELD" != "$1" ] || ! [ -e "$1" ]
  then
    return 1
  fi
  if [ "$(readlink -f "/proc/$$/fd/9" 2> /dev/null)" != "$(readlink -f "$1")" ]
  then
    return 1
  fi
  # the same open file description as the parent's: succeeds at once if the parent holds the lock
  if ! flock -n 9 2> /dev/null
  then
    return 1
  fi
  lockWriteHolder "$1" "$2" "$$"
}

# writes the holder entry into the lock file $1, in place. A failed write only costs the entry, the
# lock is held either way.
lockWriteHolder() {
  if ! printf 'holder=%s\npid=%s\nsince=%s\n' "$2" "$3" "$(stateNow)" > "$1"
  then
    echo "could not write the holder into '$1'" >&2
  fi
}

# releases the lock. The entry stays in the file; readers see that it isn't held any more.
# The unlock applies to the open file description, which stage one and stage two share: a stage one
# that has handed the lock to stage two must not call this, or it releases stage two's lock too. It
# just exits; closing its descriptor leaves stage two's lock alone.
lockRelease() {
  flock -u 9 2> /dev/null
  exec 9>&-
  unset MGW_LOCK_HELD
}

# returns 0 if someone holds the lock file $1, 1 if not (or there is no lock file), 2 if that can't be
# determined. Tries a shared lock without waiting on a descriptor of its own and releases it at once.
lockHeld() {
  if ! [ -e "$1" ]
  then
    return 1
  fi
  if ! (: 8< "$1") 2> /dev/null
  then
    return 2
  fi
  if (exec 8< "$1" && flock -s -n 8)
  then
    return 1
  fi
  return 0
}

# prints a description of the lock file $1 for messages, e.g. "locked by update (pid 1234) since
# 2026-11-09T03:00:00Z", or "not locked" with the last holder
lockDescribe() {
  recordClear lock_entry "holder pid since" ""
  recordLoad "$1" lock_entry "" 2> /dev/null
  lockHeld "$1"
  case $? in
    0)
      echo "locked by ${lock_entry_holder:-unknown} (pid ${lock_entry_pid:-unknown}) since ${lock_entry_since:-unknown}"
      ;;
    1)
      echo "not locked (last holder: ${lock_entry_holder:-none})"
      ;;
    *)
      echo "lock state unknown"
  esac
}
