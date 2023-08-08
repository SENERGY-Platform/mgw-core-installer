#!/bin/sh

getGitHubRelease() {
  url="https://api.github.com/repos/$1/releases"
  case $2 in
  "")
    url="$url/latest"
    ;;
  *)
    url="$url/tags/$2"
  esac
  if ! curl -L --progress-bar \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url"
  then
    exit 1
  fi
}

getGitHubReleaseAssetUrl() {
  if ! echo "$1" | jq -r '.assets[] | select(.name | test("'"$2"'.tar.gz"; "x")) | .browser_download_url'
  then
    exit 1
  fi
}