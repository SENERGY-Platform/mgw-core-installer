#!/bin/sh

copyContainerAssets() {
  export \
    NGINX_IMG="$nginx_img" \
    MYSQLDB_IMG="$mysqldb_img" \
    KRATOS_IMG="$kratos_img" \
    AUTH_SERVICE_IMG="$auth_service_img" \
    MODULE_MANAGER_IMG="$module_manager_img" \
    SECRET_MANAGER_IMG="$secret_manager_img" \
    WEB_UI_IMG="$web_ui_img"
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
  echo "copying docker compose file ..."
  if ! envsubst '$BASE_PATH $SECRETS_PATH $DEPLOYMENTS_PATH $SOCKETS_PATH $CONTAINER_PATH $MOUNTS_PATH $SUBNET_CORE $SUBNET_MODULE $SUBNET_GATEWAY $CORE_DB_PW $CORE_DB_ROOT_PW $CORE_ID $CORE_NAME $GATEWAY_PORT $CORE_USR_PW $NGINX_IMG $MYSQLDB_IMG $KRATOS_IMG $AUTH_SERVICE_IMG $MODULE_MANAGER_IMG $SECRET_MANAGER_IMG $WEB_UI_IMG' < ./assets/container/docker-compose.yml.template > $container_path/docker-compose.yml
  then
    exit 1
  fi
}

parseImages() {
  for item in ${images}
  do
    eval "$item"
  done
}