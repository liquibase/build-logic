#!/bin/bash

LIQUIBASE_HOME=/opt/liquibase

# Needed once the installation is complete. No need to open a new terminal
sudo echo "export LIQUIBASE_HOME=$LIQUIBASE_HOME" >> sudo /etc/profile
sudo echo "export PATH=\$PATH:\$LIQUIBASE_HOME" >> sudo /etc/profile

echo "export PATH=\$PATH:\$LIQUIBASE_HOME" >> ~/.profile

source /etc/profile