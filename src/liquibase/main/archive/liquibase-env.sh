#!/bin/sh

# Needed when restarting the terminal
echo "export LIQUIBASE_HOME=/opt/liquibase" >> ~/.profile
echo "export PATH=\$PATH:\$LIQUIBASE_HOME" >> ~/.profile
source ~/.profile
