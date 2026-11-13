#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# The scripts' log (m9-release.md): every script that changes a core writes its output, stdout and
# stderr, into <core root>/log/scripts.log as well as to the terminal, each line with the time, the
# script's name and its process id:
#
#   2026-11-12T13:06:48Z update.sh[1234]: preparing v0.40.0-alpha.3 ...
#
# The core-manager serves the file with the host binaries' logs (log_hdl.json), logrotate rotates it
# with them.
#
# How: the script's descriptors 1 and 2 go into a FIFO; a reader in the background copies what comes
# in to the terminal at once (tee: a prompt without a line break shows), and stamps it line by line
# into the log. The terminal stays on descriptor 7: a script started from a logging one (stage two, a
# hand-over to another version's recover.sh) logs with its own name and pid and writes to the same
# terminal, not into its parent's FIFO. A script that exec's another keeps its descriptors and its
# reader; the new one sees MGW_LOG_PID and doesn't start a second one.
#
# Needs nothing but sh, mktemp, mkfifo, GNU tee (--output-error) and date.

# the reader of this process, empty if this process doesn't log
log_reader=""

# starts logging this script's output into the file $1, the lines named $2. Returns 1 (and the script
# goes on without a log) if the file's folder doesn't exist or the FIFO can't be made. Nothing to do
# if this process already logs (it exec'd from a script that started the log).
logStart() {
  if [ "$MGW_LOG_PID" = "$$" ]
  then
    # exec'd from the script that started the log: its reader, waited for at the end
    log_reader="$MGW_LOG_READER"
    return 0
  fi
  if ! [ -d "${1%/*}" ]
  then
    return 1
  fi
  # a private folder with two FIFOs: in (the script's output), lines (tee's copy for the stamping)
  if ! log_dir="$(mktemp -d "${TMPDIR:-/tmp}/mgw-log.XXXXXXXX")" ||
    ! mkfifo -m 600 "$log_dir/in" "$log_dir/lines" 2> /dev/null
  then
    [ "$log_dir" = "" ] || rm -rf "$log_dir"
    return 1
  fi
  # the terminal: the parent's (descriptor 7), if a logging script started this one, otherwise this
  # script's own output
  if [ "$MGW_LOG_PID" = "" ] || ! { true >&7; } 2> /dev/null
  then
    exec 7>&1
  fi
  log_file="$1"
  log_name="$2[$$]"
  # tee passes the bytes on to the terminal (its stdout, descriptor 7) as they come and copies them
  # into the second FIFO, from which the loop stamps whole lines into the file. The terminal isn't
  # opened by name: under systemd it is a socket to the journal, which can't be opened again.
  # --output-error=warn: a terminal that went away (a lost ssh session) doesn't end the log.
  (
    trap '' INT TERM HUP
    while IFS= read -r log_line || [ -n "$log_line" ]
    do
      printf '%s %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$log_name" "$log_line" >> "$log_file"
    done < "$log_dir/lines" &
    tee --output-error=warn "$log_dir/lines" < "$log_dir/in" >&7
    wait
    rm -rf "$log_dir"
  ) > /dev/null 2>&1 &
  log_reader=$!
  exec > "$log_dir/in" 2>&1
  MGW_LOG_PID=$$
  MGW_LOG_READER=$log_reader
  export MGW_LOG_PID MGW_LOG_READER
}

# ends this script's log: closes its side of the FIFO and waits up to 5 seconds for the reader to
# write the rest. A process started for good during the run (a host binary) must get its own output
# and close descriptor 7 (as the lock's 9), or it keeps the FIFO and the terminal open.
logStop() {
  if [ "$log_reader" = "" ]
  then
    return 0
  fi
  exec 1>&7 2>&7
  log_waited=0
  while kill -0 "$log_reader" 2> /dev/null && [ "$log_waited" -lt 50 ]
  do
    sleep 0.1
    log_waited=$((log_waited + 1))
  done
  log_reader=""
}

# starts the log of the core root $1 for the script named $2 and makes sure it is ended when the
# script exits, keeping the exit code. A script without a log folder goes on without a log.
logCore() {
  if logStart "$1/log/scripts.log" "$2"
  then
    # shellcheck disable=SC2154 # log_rc is set in the trap itself
    trap 'log_rc=$?; logStop; exit $log_rc' EXIT
  fi
}

# prints $* to the terminal only, never into the log (e.g. a password)
logTerminalOnly() {
  if [ "$log_reader" != "" ] || [ "$MGW_LOG_PID" != "" ]
  then
    printf '%s\n' "$*" >&7
  else
    printf '%s\n' "$*"
  fi
}
