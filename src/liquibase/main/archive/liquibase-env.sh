#!/bin/sh

# Needed when restarting the terminal
echo "export LIQUIBASE_HOME=$LIQUIBASE_HOME" >> ~/.profile
echo "export PATH=\$PATH:\$LIQUIBASE_HOME" >> ~/.profile
source ~/.profile