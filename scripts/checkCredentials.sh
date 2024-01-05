#!/bin/bash

DBUSER=$2
DBPASSWD=$3

function checkCredentials(){
    echo "show dbs" | mongo --shell --username ${DBUSER} --password ${DBPASSWD} --authenticationDatabase admin "mongodb://localhost:27017"
}

if [ "x$1" == "xcheckCredentials" ]; then
    checkCredentials
fi
