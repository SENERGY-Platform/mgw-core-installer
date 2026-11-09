#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# Network requests with timeouts and retries (PLAN.md 12). All of them run before a core is stopped,
# so a retry costs time, never downtime.
#
# - GitHub API requests fail after 120s. Downloads have no overall limit (a slow link may need long
#   for a large file); they fail if no connection is made within 30s or they stay below 1 KiB/s for
#   60s.
# - Only transient errors are retried: timeouts, connection errors, HTTP 5xx; by default 3 attempts
#   with 30s and 2 minutes in between, each attempt with its own timeout.
# - Permanent errors (e.g. HTTP 404, 401) fail at once.
# - Rate limits are not retried, that would only use up more of the limit: GitHub answers 403 with
#   x-ratelimit-remaining 0, or 429.
#
# Return codes: 0 success, 1 failed, 3 rate limited. Errors are reported on stderr.

# the waits between attempts in seconds; one attempt more than there are waits
net_retry_delays="30 120"
net_api_timeout=120

# runs one curl attempt for the URL $1 into the file $2, with the kind $3 (api or download) and
# further curl arguments after it. Prints nothing; sets net_status (HTTP status, 000 without a
# response), net_curl_rc and net_ratelimit_remaining.
netAttempt() {
  net_url="$1"
  net_out="$2"
  net_kind="$3"
  shift 3
  net_headers="$net_out.headers"
  if [ "$net_kind" = "api" ]
  then
    set -- --max-time "$net_api_timeout" "$@"
  else
    set -- --speed-limit 1024 --speed-time 60 "$@"
  fi
  net_status="$(curl -sS -L --connect-timeout 30 -D "$net_headers" -o "$net_out" -w '%{http_code}' "$@" "$net_url" 2> "$net_out.err")"
  net_curl_rc=$?
  net_ratelimit_remaining="$(grep -i '^x-ratelimit-remaining:' "$net_headers" 2> /dev/null | tail -1 | tr -d '\r' | sed 's/^[^:]*: *//')"
  rm -f "$net_headers"
}

# classifies the last attempt: prints ok, transient, ratelimit or permanent
netClassify() {
  case "$net_curl_rc" in
    0)
      ;;
    # couldn't resolve, connect, timed out, partial or broken transfer, TLS handshake, empty reply
    5|6|7|18|28|35|52|55|56)
      echo transient
      return
      ;;
    *)
      echo permanent
      return
  esac
  case "$net_status" in
    2??)
      echo ok
      ;;
    429)
      echo ratelimit
      ;;
    403)
      if [ "$net_ratelimit_remaining" = "0" ]
      then
        echo ratelimit
      else
        echo permanent
      fi
      ;;
    5??)
      echo transient
      ;;
    *)
      echo permanent
  esac
}

# fetches the URL $1 into the file $2 as kind $3 (api or download), retrying transient errors.
# Further arguments are passed to curl (e.g. headers).
netFetch() {
  net_f_url="$1"
  net_f_out="$2"
  net_f_kind="$3"
  shift 3
  net_f_delays="$net_retry_delays"
  net_f_attempt=1
  while true
  do
    netAttempt "$net_f_url" "$net_f_out" "$net_f_kind" "$@"
    net_f_class="$(netClassify)"
    net_f_err="$(cat "$net_f_out.err" 2> /dev/null)"
    rm -f "$net_f_out.err"
    case "$net_f_class" in
      ok)
        return 0
        ;;
      ratelimit)
        echo "$net_f_url: rate limited (HTTP $net_status), not retrying" >&2
        rm -f "$net_f_out"
        return 3
        ;;
      permanent)
        echo "$net_f_url: failed (HTTP $net_status${net_f_err:+, $net_f_err})" >&2
        rm -f "$net_f_out"
        return 1
    esac
    net_f_delay="${net_f_delays%% *}"
    if [ "$net_f_delays" = "" ]
    then
      echo "$net_f_url: failed after $net_f_attempt attempts (HTTP $net_status${net_f_err:+, $net_f_err})" >&2
      rm -f "$net_f_out"
      return 1
    fi
    case "$net_f_delays" in
      *" "*)
        net_f_delays="${net_f_delays#* }"
        ;;
      *)
        net_f_delays=""
    esac
    echo "$net_f_url: attempt $net_f_attempt failed (HTTP $net_status${net_f_err:+, $net_f_err}), retrying in ${net_f_delay}s" >&2
    sleep "$net_f_delay"
    net_f_attempt=$((net_f_attempt + 1))
  done
}

# fetches the GitHub release $2 (a tag, empty for the latest) of the repository $1 (owner/name) into
# the file $3
githubRelease() {
  github_url="https://api.github.com/repos/$1/releases"
  if [ "$2" = "" ]
  then
    github_url="$github_url/latest"
  else
    github_url="$github_url/tags/$2"
  fi
  netFetch "$github_url" "$3" api -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28"
}

# fetches the list of releases of the repository $1 into the file $2
githubReleases() {
  netFetch "https://api.github.com/repos/$1/releases" "$2" api -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28"
}

# prints the download URL of the asset whose name ends in $2 in the release JSON file $1
githubAssetUrl() {
  github_asset="$(jq -r --arg suffix "$2" '.assets[] | select(.name | endswith($suffix)) | .browser_download_url' "$1" 2> /dev/null | head -1)"
  if [ "$github_asset" = "" ]
  then
    echo "no release asset ending in '$2'" >&2
    return 1
  fi
  echo "$github_asset"
}

# downloads the URL $1 into the file $2
netDownload() {
  netFetch "$1" "$2" download
}
