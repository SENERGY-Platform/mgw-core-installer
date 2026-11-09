# Copyright (c) 2026 InfAI (CC SES)

# Shared by the unit tests. The tests run under bats (bash); the code under test runs under dash, the
# shell the scripts get on Debian gateways.

LIB="$(cd "$BATS_TEST_DIRNAME/../../assets/scripts/lib" && pwd)"
export LIB

# runs the shell code $1 under dash after sourcing the libraries named in $2.. (without .sh)
dsh() {
  local code="$1" pre="" lib
  shift
  for lib in "$@"; do
    pre="$pre. \"\$LIB/$lib.sh\" || exit 99; "
  done
  dash -c "$pre$code"
}
