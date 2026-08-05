#!/bin/sh

startContainers() {
  echo "starting containers ..."
  if ! cd $container_path
  then
    exit 1
  fi
  if ! dockerCompose start
  then
    exit 1
  fi
  if ! cd $script_path
  then
    exit 1
  fi
}

stopContainers() {
  echo "stopping containers ..."
  if ! cd $container_path
  then
    exit 1
  fi
  if ! dockerCompose stop
  then
    exit 1
  fi
  if ! cd $script_path
  then
    exit 1
  fi
}

createContainers() {
  echo "creating containers ..."
  if ! cd $container_path
  then
    exit 1
  fi
  if ! dockerCompose up --no-start
  then
    exit 1
  fi
  if ! cd $script_path
  then
    exit 1
  fi
}

removeContainers() {
  echo "removing containers ..."
  if ! cd $container_path
  then
    exit 1
  fi
  if ! dockerCompose rm -s -f
  then
    exit 1
  fi
  if ! cd $script_path
  then
    exit 1
  fi
}

purgeContainers() {
  echo "purging containers ..."
  if ! cd $container_path
  then
    exit 1
  fi
  if ! dockerCompose down -v
  then
    exit 1
  fi
  if ! cd $script_path
  then
    exit 1
  fi
}

# TODO remove
buildModuleManager() {
  echo "building module-manager ..."
  if ! cd $container_path
  then
    exit 1
  fi
  if ! dockerCompose build --build-arg VERSION="dev-$(date +%s)" module-manager
  then
    exit 1
  fi
  if ! cd $script_path
  then
    exit 1
  fi
}
