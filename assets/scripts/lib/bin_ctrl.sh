#!/bin/sh

# host binaries in start order, mapped to the base name of the file their
# stdout and stderr is redirected to
bin_procs="SENERGY-Platform/mgw-container-engine-wrapper:ce_wrapper
SENERGY-Platform/mgw-host-manager:h_manager
SENERGY-Platform/mgw-core-manager:c_manager"

mountTmpfs() {
  res=$(stat -f -c '%T' $secrets_path)
  if [ "$res" != "tmpfs" ]
  then
    echo "mounting tmpfs ..."
    if ! mount -t tmpfs -o size=100M tmpfs $secrets_path
    then
      exit 1
    fi
  fi
}

unmountTmpfs() {
  if [ "$(stat -f -c '%T' $secrets_path 2> /dev/null)" != "tmpfs" ]
  then
    return
  fi
  echo "unmounting tmpfs ..."
  umount -f $secrets_path
}

# checks whether $1 is a living process
procAlive() {
  kill -0 "$1" 2> /dev/null
}

# prints the pid from the list in $1 that runs the binary $2, returns 1 if none
# does. the binary has to be matched because the pids in .pid are meaningless
# after a host reboot, where they may well belong to unrelated processes
findProc() {
  for pid in ${1}
  do
    if [ "$({ tr '\0' '\n' < /proc/$pid/cmdline | head -1; } 2> /dev/null)" = "$2" ]
    then
      echo "$pid"
      return 0
    fi
  done
  return 1
}

# prints the binary:pid list of the host binaries that are running, taking the
# pids to check from .pid
listProcs() {
  procs=""
  if [ -e $base_path/.pid ]
  then
    listed_pids="$(readFileToArray $base_path/.pid)"
    for item in ${bin_procs}
    do
      repo="${item%%:*}"
      if pid="$(findProc "$listed_pids" "$bin_path/$repo/bin")"
      then
        procs="${procs}$repo:$pid "
      fi
    done
  fi
  echo "$procs"
}

# prints the host binaries missing from the binary:pid list in $1
missingProcs() {
  missing=""
  for item in ${bin_procs}
  do
    repo="${item%%:*}"
    found=false
    for proc in ${1}
    do
      if [ "${proc%%:*}" = "$repo" ]
      then
        found=true
        break
      fi
    done
    if [ "$found" = "false" ]
    then
      missing="${missing}$repo "
    fi
  done
  echo "$missing"
}

# prints the pids of the binary:pid list in $1
procPids() {
  pids=""
  for item in ${1}
  do
    pids="${pids}${item##*:} "
  done
  echo "$pids"
}

# terminates the processes in $1 and waits for them to exit, SIGKILL after 10s
killProcs() {
  for pid in ${1}
  do
    kill "$pid" 2> /dev/null
  done
  for pid in ${1}
  do
    count=0
    while procAlive "$pid"
    do
      if [ "$count" -ge 100 ]
      then
        echo "process $pid did not terminate, sending SIGKILL ..."
        kill -9 "$pid" 2> /dev/null
        break
      fi
      sleep 0.1
      count=$((count + 1))
    done
  done
}

# starts the binary $1 with the config $2, redirects its output to $3 and
# appends its pid to .pid. the wrapper shell reports its own pid and then
# replaces itself with the binary, so the pid recorded is the pid of the
# binary. setsid makes the binary a session leader without a controlling
# terminal and the redirections drop every file descriptor of the caller, so
# the binary outlives the shell, ssh session, cron job or ci step that called
# ctrl.sh instead of dying on the SIGHUP that is sent when that session ends
startProc() {
  setsid sh -c 'echo $$ >> "$4"; exec "$1" -config="$2" < /dev/null >> "$3" 2>&1' \
    sh "$1" "$2" "$3" "$base_path/.pid" &
}

startBin() {
  if [ -e $base_path/.pid ]
  then
    # a pid file that accounts for every binary is the only state start has
    # nothing to do about, anything else is a leftover that would otherwise
    # turn start into a silent no-op
    running="$(listProcs)"
    if [ "$(missingProcs "$running")" = "" ]
    then
      echo "processes already running"
      return
    fi
    if [ "$running" != "" ]
    then
      echo "stopping incomplete set of processes ..."
      killProcs "$(procPids "$running")"
    else
      echo "removing stale pid file ..."
    fi
    if ! rm $base_path/.pid
    then
      exit 1
    fi
  fi
  if ! [ -d "$log_path" ]
  then
    echo "log path '$log_path' not found"
    exit 1
  fi
  echo "starting processes ..."
  for item in ${bin_procs}
  do
    repo="${item%%:*}"
    startProc \
      "$bin_path/$repo/bin" \
      "$bin_path/$repo/config/conf.json" \
      "$log_path/${item##*:}_out.log"
  done
  # a binary that exits right away, on a bad config for example, must not be
  # reported as started
  sleep 1
  running="$(listProcs)"
  missing="$(missingProcs "$running")"
  if [ "$missing" != "" ]
  then
    echo "processes did not start: $missing"
    echo "see the logs in $log_path for details"
    killProcs "$(procPids "$running")"
    rm -f $base_path/.pid
    exit 1
  fi
}

stopBin() {
  running="$(listProcs)"
  if [ "$running" != "" ]
  then
    echo "stopping processes ..."
    killProcs "$(procPids "$running")"
  else
    echo "no processes to stop"
  fi
  if [ -e $base_path/.pid ]
  then
    if ! rm $base_path/.pid
    then
      exit 1
    fi
  fi
}
