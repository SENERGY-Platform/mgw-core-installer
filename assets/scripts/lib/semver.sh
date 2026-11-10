#!/bin/sh

# Copyright (c) 2026 InfAI (CC SES)

# Release versions (PLAN.md 3): vMAJOR.MINOR.PATCH, optionally with -alphaN or -betaN (e.g.
# v0.33.0-beta2). Every number may have several digits. A pre-release comes before its release, an
# alpha before a beta: v1.2.3-alpha2 < v1.2.3-beta1 < v1.2.3 < v1.2.4-alpha1.

# splits the version $1 into semver_major, semver_minor, semver_patch, semver_pre (0 alpha, 1 beta,
# 2 release) and semver_pre_n; returns 1 if it isn't a release version
semverParse() {
  semver_rest="${1#v}"
  case "$1" in
    v*)
      ;;
    *)
      return 1
  esac
  semver_pre=2
  semver_pre_n=0
  case "$semver_rest" in
    *-alpha*)
      semver_pre=0
      semver_pre_n="${semver_rest##*-alpha}"
      semver_rest="${semver_rest%-alpha*}"
      ;;
    *-beta*)
      semver_pre=1
      semver_pre_n="${semver_rest##*-beta}"
      semver_rest="${semver_rest%-beta*}"
      ;;
    *-*)
      return 1
  esac
  case "$semver_rest" in
    *.*.*.*)
      return 1
      ;;
    *.*.*)
      ;;
    *)
      return 1
  esac
  semver_major="${semver_rest%%.*}"
  semver_rest="${semver_rest#*.}"
  semver_minor="${semver_rest%%.*}"
  semver_patch="${semver_rest#*.}"
  for semver_n in "$semver_major" "$semver_minor" "$semver_patch" "$semver_pre_n"
  do
    case "$semver_n" in
      ""|*[!0-9]*)
        return 1
    esac
    # no leading zeros, they would read as octal in arithmetic
    case "$semver_n" in
      0?*)
        return 1
    esac
  done
}

# returns 0 if $1 is a release version
semverValid() {
  semverParse "$1"
}

# returns 0 if $1 is a pre-release (alpha or beta)
semverIsPre() {
  semverParse "$1" && [ "$semver_pre" -lt 2 ]
}

# prints -1, 0 or 1 as the version $1 is lower than, equal to or higher than $2; returns 1 if one
# of them isn't a release version
semverCompare() {
  semverParse "$1" || return 1
  semver_a="$semver_major $semver_minor $semver_patch $semver_pre $semver_pre_n"
  semverParse "$2" || return 1
  # shellcheck disable=SC2086 # one number per argument
  set -- $semver_a "$semver_major" "$semver_minor" "$semver_patch" "$semver_pre" "$semver_pre_n"
  while [ $# -gt 5 ]
  do
    if [ "$1" -lt "$6" ]
    then
      echo -1
      return 0
    fi
    if [ "$1" -gt "$6" ]
    then
      echo 1
      return 0
    fi
    shift
  done
  echo 0
}

# returns 0 if the version $1 is lower than $2
semverLess() {
  [ "$(semverCompare "$1" "$2")" = "-1" ]
}
