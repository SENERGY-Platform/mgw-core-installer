#!/bin/sh

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
  echo "copying docker compose file ..."
  if ! envsubst '$BASE_PATH $SECRETS_PATH $DEPLOYMENTS_PATH $SOCKETS_PATH $CONTAINER_PATH $SUBNET_CORE $SUBNET_MODULE $SUBNET_GATEWAY $CORE_DB_PW $CORE_DB_ROOT_PW $CORE_ID $CORE_NAME $GATEWAY_PORT $CORE_USR_PW' < ./assets/container/docker-compose.yml.template > $container_path/docker-compose.yml
  then
    exit 1
  fi
}