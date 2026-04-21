#!/bin/bash -e

echo "Processing liquibase tasks ..."
case "$1" in
    "version" )
        echo "Checking liquibase version ..."
        sh /scripts/liquibase_version.sh
        ;;
    * )
        echo "Unsupported liquibase test command: $1" >&2
        exit 64
        ;;
esac