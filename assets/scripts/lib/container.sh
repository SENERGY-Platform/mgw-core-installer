#!/bin/sh

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

parseImages() {
  for item in ${images}
  do
    eval "export ${item%%=*}=${item##*=}"
  done
}
