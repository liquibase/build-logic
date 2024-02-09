#!/usr/bin/env bash

set -e

KEY=$1

if [[ -z "$GITHUB_TOKEN" ]]; then
  echo "Set the GITHUB_TOKEN env variable."
  exit 1
fi

if [[ -z "$GITHUB_REPOSITORY" ]]; then
  echo "Set the GITHUB_REPOSITORY env variable."
  exit 1
fi

echo "GITHUB_REPOSITORY: $GITHUB_REPOSITORY"

RELEASE=$(curl -s \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$GITHUB_REPOSITORY/releases" |
    jq -r ".[] | select(.draft == true)")

echo "RELEASE: $RELEASE"

if [[ "${#RELEASE}" -eq 0 ]]; then
    echo "Draft release not found."
    exit 1;
fi

case $KEY in
    TAG)
        HTML_URL=$(echo $RELEASE | jq -r ".html_url")
        echo "$HTML_URL" | rev | cut -d "/" -f1 | rev
        ;;
    UPLOAD_URL)
        UPLOAD_URL=$(echo $RELEASE | jq -r ".upload_url")
        echo "GENERATED_UPLOAD_URL: $UPLOAD_URL"
        echo "${UPLOAD_URL//{?name,label\}}"
        ;;
esac