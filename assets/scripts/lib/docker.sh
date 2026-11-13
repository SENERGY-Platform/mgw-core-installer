#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# Docker calls with time limits and retries (PLAN.md 12).
#
# - In an automatic update, docker calls are limited: pulling to 30 minutes per image; creating,
#   stopping, starting and removing containers to 10 minutes each. A call that runs out is killed.
#   The limit runs the call in a process group of its own (timeout), which also reaches the compose
#   plugin the docker CLI runs as a child, but not Ctrl-C. So a manual run has no limits (0) and can be
#   aborted with Ctrl-C.
# - Image pulls are retried like network requests (lib/net.sh: net_retry_delays), except when the
#   image doesn't exist or the registry's rate limit is reached.
# - An image already on the host is not pulled again (dockerPullImages).
# - Every image is added to state/images before its pull, so an image whose pull completes right
#   before a kill is still listed for the cleanup (PLAN.md 9, 11).
#
# Only the compose plugin (docker compose) is supported, in the versions dockerComposeCheck accepts.
#
# Return codes like lib/net.sh: 0 success, 1 failed, 3 rate limited.
#
# Needs lib/file.sh and lib/state.sh (imagesAdd), and net_retry_delays from lib/net.sh.

# docker_*_limit are used by the callers
# shellcheck disable=SC2034,SC2154 # net_retry_delays comes from lib/net.sh

docker_pull_limit=1800
docker_ctr_limit=600

# runs the command after $1 with a limit of $1 seconds, 0 meaning no limit. A command that runs out
# gets SIGTERM, 30 seconds later SIGKILL; returns 124 or 137 then.
limitRun() {
  limit_run_s="$1"
  shift
  if [ "$limit_run_s" = "0" ]
  then
    "$@"
    return
  fi
  timeout -k 30 "$limit_run_s" "$@"
  limit_run_rc=$?
  if [ $limit_run_rc -eq 124 ] || [ $limit_run_rc -eq 137 ]
  then
    echo "'$*' killed after ${limit_run_s}s" >&2
  fi
  return $limit_run_rc
}

# the compose plugin versions the scripts work with, tested against every release on Docker 20.10
# (Debian 12's own package): 2.9.0 and newer (up --pull came with 2.8.0, which names a project's
# volumes <project>-<volume> instead of <project>_<volume>), except the releases in
# docker_compose_broken. docker-compose v1 isn't supported: it rejects the compose file's "name" and
# its up --no-start waits for containers that never start.
docker_compose_min=2.9.0
# 2.19.0: recreating containers fails now and then ("is not connected to the network"); 2.25.0:
# config ignores --format json; 5.1.0, 5.1.1: don't negotiate the API version (always 1.53), failed
# with Docker 20.10 (API 1.41); refused with every engine, newer ones weren't tested
docker_compose_broken="2.19.0 2.25.0 5.1.0 5.1.1"

# returns 0 if the version $1 (2.8.0, v2.0.0, 2.24.6-desktop.1) is $2 (x.y.z) or newer
dockerVersionAtLeast() {
  docker_va="${1#v}"
  docker_va="${docker_va%%[!0-9.]*}"
  docker_vb="$2"
  while [ "$docker_va$docker_vb" != "" ]
  do
    docker_a="${docker_va%%.*}"
    docker_b="${docker_vb%%.*}"
    case "$docker_va" in
      *.*) docker_va="${docker_va#*.}" ;;
      *) docker_va="" ;;
    esac
    case "$docker_vb" in
      *.*) docker_vb="${docker_vb#*.}" ;;
      *) docker_vb="" ;;
    esac
    if [ "${docker_a:-0}" -gt "${docker_b:-0}" ]
    then
      return 0
    fi
    if [ "${docker_a:-0}" -lt "${docker_b:-0}" ]
    then
      return 1
    fi
  done
  return 0
}

# returns 0 if docker and a compose plugin the scripts work with are installed; otherwise prints why
# to stderr and returns 1. Only reads: for the checks before anything is changed or downloaded.
dockerComposeCheck() {
  if ! command -v docker > /dev/null 2>&1
  then
    echo "docker is required, see https://docs.docker.com/engine/install" >&2
    return 1
  fi
  docker_compose_v="$(docker compose version --short 2> /dev/null)"
  if [ "$docker_compose_v" = "" ]
  then
    echo "the docker compose plugin is required (docker-compose v1 isn't supported), $docker_compose_min or newer, see https://docs.docker.com/compose/install/linux" >&2
    return 1
  fi
  if ! dockerVersionAtLeast "$docker_compose_v" "$docker_compose_min"
  then
    echo "the docker compose plugin $docker_compose_v is too old, $docker_compose_min or newer is required, see https://docs.docker.com/compose/install/linux" >&2
    return 1
  fi
  docker_compose_n="${docker_compose_v#v}"
  docker_compose_n="${docker_compose_n%%[!0-9.]*}"
  for docker_compose_b in ${docker_compose_broken}
  do
    if [ "$docker_compose_n" = "$docker_compose_b" ]
    then
      echo "the docker compose plugin $docker_compose_v has a bug the installer can't work with, update it, see https://docs.docker.com/compose/install/linux" >&2
      return 1
    fi
  done
}

# runs docker compose with the arguments after $1, limited to $1 seconds (0: no limit)
dockerCompose() {
  docker_compose_limit="$1"
  shift
  limitRun "$docker_compose_limit" docker compose "$@"
}

# classifies the output $1 of a failed pull: prints permanent, ratelimit or transient
dockerPullClassify() {
  case "$1" in
    *toomanyrequests*|*"429 Too Many Requests"*|*"rate limit"*)
      echo ratelimit
      ;;
    *"manifest unknown"*|*"not found"*|*"pull access denied"*|*"repository does not exist"*|*unauthorized*|*"invalid reference format"*|*denied*)
      echo permanent
      ;;
    *)
      echo transient
  esac
}

# pulls the image $1, each attempt limited to $2 seconds (0: no limit), retrying transient failures
dockerPull() {
  docker_pull_delays="$net_retry_delays"
  docker_pull_attempt=1
  while true
  do
    if docker_pull_out="$(limitRun "$2" docker pull -q "$1" 2>&1)"
    then
      return 0
    fi
    docker_pull_out="$(printf '%s' "$docker_pull_out" | tail -3 | tr '\n' ' ')"
    case "$(dockerPullClassify "$docker_pull_out")" in
      ratelimit)
        echo "pulling $1: rate limited, not retrying: $docker_pull_out" >&2
        return 3
        ;;
      permanent)
        echo "pulling $1 failed: $docker_pull_out" >&2
        return 1
    esac
    if [ "$docker_pull_delays" = "" ]
    then
      echo "pulling $1 failed after $docker_pull_attempt attempts: $docker_pull_out" >&2
      return 1
    fi
    docker_pull_delay="${docker_pull_delays%% *}"
    case "$docker_pull_delays" in
      *" "*)
        docker_pull_delays="${docker_pull_delays#* }"
        ;;
      *)
        docker_pull_delays=""
    esac
    echo "pulling $1: attempt $docker_pull_attempt failed, retrying in ${docker_pull_delay}s: $docker_pull_out" >&2
    sleep "$docker_pull_delay"
    docker_pull_attempt=$((docker_pull_attempt + 1))
  done
}

# pulls the images after $2, each listed in the images file $1 before its pull. Each pull attempt is
# limited to $2 seconds (0: no limit; docker_pull_limit in automatic runs). Stops at the first failure.
#
# An image already on the host under its tag is used as it is, not pulled again (decided 2026-11-12,
# PLAN.md 18): every pull asks the registry, which counts against Docker Hub's rate limit per IP, and
# the tags in options are pinned versions. A tag that was pushed again with new content is then never
# fetched. It is listed all the same: it belongs to the core for the cleanup and the uninstall.
dockerPullImages() {
  docker_images_file="$1"
  docker_images_limit="$2"
  shift 2
  for docker_image in "$@"
  do
    if ! imagesAdd "$docker_images_file" "$docker_image"
    then
      echo "cannot record $docker_image in '$docker_images_file', not pulling it" >&2
      return 1
    fi
    if docker image inspect "$docker_image" > /dev/null 2>&1
    then
      echo "$docker_image is present"
      continue
    fi
    echo "pulling $docker_image ..."
    dockerPull "$docker_image" "$docker_images_limit"
    docker_images_rc=$?
    if [ $docker_images_rc -ne 0 ]
    then
      return $docker_images_rc
    fi
  done
}
