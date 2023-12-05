#!/bin/sh

basic_auth_pw=""

handleGatewayUserFile() {
  echo "writing gateway user file ..."
  if ! htpasswd -bc $base_path/.htpasswd "admin" "$basic_auth_pw"
  then
    exit 1
  fi
}
