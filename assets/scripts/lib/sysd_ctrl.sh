#!/bin/sh

stopUnits() {
  installed_units="$(readFileToArray $base_path/.units)"
  for unit in ${installed_units}
  do
    echo "stopping $unit ..."
    if ! systemctl stop "$unit"
    then
      exit 1
    fi
  done
}

startUnits() {
  installed_units="$(readFileToArray $base_path/.units)"
  for unit in ${installed_units}
  do
    echo "starting $unit ..."
    if ! systemctl start "$unit"
    then
      exit 1
    fi
  done
}

disableUnits() {
  installed_units="$(readFileToArray $base_path/.units)"
  for unit in ${installed_units}
  do
    echo "disabling $unit ..."
    if ! systemctl disable "$unit"
    then
      exit 1
    fi
  done
}

enableUnits() {
  installed_units="$(readFileToArray $base_path/.units)"
  for unit in ${installed_units}
  do
    echo "enabling $unit ..."
    if ! systemctl enable "$unit"
    then
      exit 1
    fi
  done
}