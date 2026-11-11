#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# Runs the VM tests: builds the fake host binary, copies the repository to the test VM and runs
# "sudo bats" there on tests/vm (or the files given as arguments, relative to the repository).
#
#   tests/vm/run.sh [-j <jobs>] [tests/vm/core.bats ...]
#
# -j runs that many test files in parallel (GNU parallel on the VM); the tests within a file always run
# in order. The files use subnets and ports of their own, so they don't collide.
#
# MGW_TEST_VM (default mgw-user@192.168.122.253) and MGW_TEST_VM_KEY (default
# ~/.ssh/mgw_test_vm_ed25519) select the VM. Needs go locally, bats and sudo on the VM. The fake
# binary is only built for the copy and removed locally afterwards.

set -e
jobs=""
if [ "$1" = "-j" ]
then
  jobs="--jobs $2 --no-parallelize-within-files"
  shift 2
fi
cd "$(dirname "$0")/../.."
vm="${MGW_TEST_VM:-mgw-user@192.168.122.253}"
key="${MGW_TEST_VM_KEY:-$HOME/.ssh/mgw_test_vm_ed25519}"
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o tests/vm/fakebin/fakebin tests/vm/fakebin/main.go
tar -cz --exclude=.git --exclude=docs --exclude=.claude . |
  ssh -i "$key" -o BatchMode=yes "$vm" 'rm -rf ~/mgw-core-installer && mkdir -p ~/mgw-core-installer && tar -xz -C ~/mgw-core-installer'
rm -f tests/vm/fakebin/fakebin
# shellcheck disable=SC2029 # the test files are named on this side
# keepers hold the core images during the run (tests/vm/keepers.sh); the exit code is the tests'
ssh -i "$key" -o BatchMode=yes "$vm" "cd ~/mgw-core-installer && sudo tests/vm/keepers.sh create && { sudo bats $jobs ${*:-tests/vm}; rc=\$?; sudo tests/vm/keepers.sh remove; exit \$rc; }"
