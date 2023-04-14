#!/usr/bin/env bash

set -e

if [[ -z "$GITHUB_TOKEN" ]]; then
  echo "Set the GITHUB_TOKEN env variable."
  exit 1
fi

if [[ -z "$ASSET_NAME_PREFIX" ]]; then
  echo "Set the ASSET_NAME_PREFIX env variable."
  exit 1
fi

if [[ -z "$ASSET_DIR" ]]; then
  echo "Set the ASSET_DIR env variable."
  exit 1
fi

VERSION=$1
if [[ -z "$VERSION" ]]; then
  echo "Set the VERSION parameter."
  exit 1
fi

_DIR=$(dirname "$0")
UPLOAD_URL=$($_DIR/get_draft_release.sh UPLOAD_URL)

upload_asset() {
    local file=$1
    local size=$2
    local content_type=$3
    curl \
      -H "Authorization: token $GITHUB_TOKEN" \
      -H "Content-Length: $size"\
      -H "Content-Type: $content_type" \
      --data-binary @$file "$UPLOAD_URL?name=$(basename $file)"
}

declare -a StringArray=(".jar" ".jar.asc" ".jar.md5" ".jar.sha1" \
 ".pom" ".pom.asc" ".pom.md5" ".pom.sha1" \
 ".zip" \
 "-javadoc.jar" "-javadoc.jar.asc" "-javadoc.jar.md5" "-javadoc.jar.sha1" \
 "-sources.jar" "-sources.jar.asc" "-sources.jar.md5" "-sources.jar.sha1" )

# temp logic to create an empty .zip file for all extensions that do not generate .zip files
ZIP_FILENAME="$ASSET_DIR/$ASSET_NAME_PREFIX$VERSION.zip"
if [[ ! -f $ZIP_FILENAME ]]; then
  touch $ZIP_FILENAME
fi 

for val in "${StringArray[@]}"; do
    FILE=$ASSET_DIR/$ASSET_NAME_PREFIX$VERSION$val
    # Skip if zip files do not exist (some extensions do not generate examples in zip format)
    if [[ ! -f "$FILE" && "$FILE" != *".zip" ]]; then
        echo "$FILE does not exist."
        exit 1
    fi
    SIZE=$(wc -c $FILE | awk '{print $1}')
    #  if the file size is 0 and FILE is not a zip file then exit
    if [[ $SIZE -eq 0 && "$FILE" != $ZIP_FILENAME ]]; then
        echo "$FILE is empty."
        exit 1;
    fi
    MIME=$(file -b --mime-type $FILE)
    upload_asset $FILE $SIZE $MIME
done