#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# writes stdin to $1 so that a reader sees either the old or the new file, never half of one: the
# content goes to a temp file next to it, is flushed to disk and then renamed over $1. The flush
# matters on gateways with SD cards, where a power loss after a rename of unflushed data can leave
# an empty file. The temp file is created with mode 600, because settings and records may hold
# passwords; $2 sets another mode. A failed write leaves $1 as it was and removes the temp file.
fileWriteAtomic() {
  file_tmp="$1.tmp.$$"
  if ! (umask 077 && cat > "$file_tmp")
  then
    rm -f "$file_tmp"
    return 1
  fi
  if [ "$2" != "" ] && ! chmod "$2" "$file_tmp"
  then
    rm -f "$file_tmp"
    return 1
  fi
  if ! sync "$file_tmp" 2> /dev/null && ! sync
  then
    rm -f "$file_tmp"
    return 1
  fi
  if ! mv -f "$file_tmp" "$1"
  then
    rm -f "$file_tmp"
    return 1
  fi
}
