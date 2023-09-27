#!/bin/sh

getMissingDockerPkg() {
  missing=""
  if ! command -v docker > /dev/null 2>& 1
  then
    missing="${missing}docker-ce docker-ce-cli containerd.io"
  fi
  if ! dockerCompose version > /dev/null 2>& 1
  then
    pkg="docker-compose-plugin"
    if [ "$missing" = "" ]; then
      missing="${missing}$pkg"
    else
      missing="${missing} $pkg"
    fi
  fi
  echo "$missing"
}

detectDockerCompose() {
  if docker compose version > /dev/null 2>& 1
  then
    alias dockerCompose="docker compose"
    return
  fi
  if docker-compose version > /dev/null 2>& 1
  then
    alias dockerCompose="docker-compose"
  fi
}
