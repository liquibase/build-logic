#!/usr/bin/env bash

set -ex

ARTIFACT=$1

if [[ ! -f "$ARTIFACT" ]]; then
    echo "$ARTIFACT does not exist."
    exit 1
fi

gpg -v --sign --armor --detach-sign "$ARTIFACT"
shasum -b -a 1 "$ARTIFACT" | cut -d " " -f 1 > "$ARTIFACT.sha1"
md5sum -b "$ARTIFACT" | cut -d " " -f 1 > "$ARTIFACT.md5"