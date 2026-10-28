#!/bin/sh

old_compose=false

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
    return
  fi
  if docker-compose version > /dev/null 2>& 1
  then
    old_compose=true
  fi
}

dockerCompose() {
  if [ "$old_compose" = "true" ]; then
    docker-compose "$@"
    return $?
  fi
  docker compose "$@"
  return $?
}

# runs docker compose like dockerCompose, but kills it after $1 seconds, 0
# meaning no limit. timeout starts it in a process group of its own and kills
# the whole group, which includes the compose plugin the docker cli runs as a
# child - --foreground would leave the plugin running. that group is out of
# reach of Ctrl-C, so a limit only suits a run nobody watches, and without one
# timeout is not involved at all
dockerComposeTimeout() {
  limit="$1"
  shift
  if [ "$limit" = "0" ]; then
    dockerCompose "$@"
    return $?
  fi
  cmd="docker compose"
  if [ "$old_compose" = "true" ]; then
    cmd="docker-compose"
  fi
  timeout -k 30 "$limit" $cmd "$@"
  rc=$?
  if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then
    echo "docker compose $1 timed out after ${limit}s"
  fi
  return $rc
}

# renders the compose file from the template installed next to it. reading the
# installed copy instead of the one in the release archive is what lets ctrl.sh
# re-render on a host that has no archive, when a setting the template uses
# changes after the installation
renderCompose() {
  echo "rendering compose file ..."
  if ! envsubst '$BASE_PATH $SECRETS_PATH $DEPLOYMENTS_PATH $SOCKETS_PATH $CONTAINER_PATH $MOUNTS_PATH $SUBNET_CORE $SUBNET_MODULE $SUBNET_GATEWAY $CORE_DB_PW $CORE_DB_ROOT_PW $CORE_ID $CORE_NAME $GATEWAY_PORT $CORE_USR $CORE_USR_PW $NGINX_IMG $MYSQLDB_IMG $KRATOS_IMG $AUTH_SERVICE_IMG $MODULE_MANAGER_IMG $MODULE_MANAGER_MIGRATION_IMG $SECRET_MANAGER_IMG $WEB_UI_IMG $HOST_DIR_REPOSITORY_PATH $CTR_RESTART_POLICY' < $container_path/docker-compose.yml.template > $container_path/docker-compose.yml
  then
    exit 1
  fi
}

copyContainerAssets() {
  echo "copying container configs ..."
  if ! cp -r ./assets/container/configs $container_path
  then
    exit 1
  fi
  echo "copying environment file ..."
  if ! cp ./assets/container/.env $container_path/.env
  then
    exit 1
  fi
  echo "copying compose template ..."
  if ! cp ./assets/container/docker-compose.yml.template $container_path/docker-compose.yml.template
  then
    exit 1
  fi
  renderCompose
}

# pulls the images of the release one by one, killing a pull after $1 seconds,
# 0 meaning no limit - see dockerComposeTimeout for why a limit only suits a run
# nobody watches. works from the images list in .options instead of the
# rendered compose file, so it needs nothing of the installation and can run
# while the core still does
pullImages() {
  for item in ${images}
  do
    image="${item##*=}"
    echo "pulling $image ..."
    if [ "$1" = "0" ]
    then
      if ! docker pull "$image"
      then
        return 1
      fi
      continue
    fi
    timeout -k 30 "$1" docker pull "$image"
    rc=$?
    if [ $rc -eq 124 ] || [ $rc -eq 137 ]
    then
      echo "docker pull $image timed out after ${1}s"
    fi
    if [ $rc -ne 0 ]
    then
      return 1
    fi
  done
}

parseImages() {
  for item in ${images}
  do
    eval "export ${item%%=*}=${item##*=}"
  done
}
