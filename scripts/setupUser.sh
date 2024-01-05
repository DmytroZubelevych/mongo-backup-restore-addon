#!/bin/bash

USER=$1
PASSWORD=$2
USER_EMAIL=$3
ENV_NAME=$4
USER_SESSION=$5
ADMIN_PASSWORD=$(pwgen 10 1)
JEM=$(which jem)
MYSQL=$(which mysql)
EMAIL_ERROR_LOG_MESSAGE="Email notification is not sent because this functionality is unavailable for current platform version."
cmd="CREATE USER '$USER'@'localhost' IDENTIFIED BY '$PASSWORD'; CREATE USER '$USER'@'%' IDENTIFIED BY '$PASSWORD'; GRANT ALL PRIVILEGES ON *.* TO '$USER'@'localhost' WITH GRANT OPTION; GRANT ALL PRIVILEGES ON *.* TO '$USER'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES;"
unset resp;
resp=$(mysql -u$USER -p$PASSWORD mysql --execute="SHOW COLUMNS FROM user")
[ -z "$resp" ] && {
   encPass=$(echo $ADMIN_PASSWORD | openssl enc -e -a -A -aes-128-cbc -nosalt -pass "pass:TFVhBKDOSBspeSXesw8fElCcOzbJzYed")
   $JEM passwd set -p static:$encPass
   $MYSQL -uroot -p${ADMIN_PASSWORD} --execute="$cmd"
     if [ -e "/usr/lib/jelastic/modules/api.module" ]; then
        [ -e "/var/run/jem.pid" ] && return 0;
        CURRENT_PLATFORM_MAJOR_VERSION=$(jem api apicall -s --connect-timeout 3 --max-time 15 [API_DOMAIN]/1.0/statistic/system/rest/getversion 2>/dev/null |jq .version|grep -o [0-9.]*|awk -F . '{print $1$2}')
        if [ "${CURRENT_PLATFORM_MAJOR_VERSION}" -ge "71" ]; then
            echo "Sending e-mail notification about setting the root password"
            SUBJECT="Password for 'root' database user has been changed during the database restore in the $ENV_NAME environment"
            BODY="Password for 'root' database user has been set to $ADMIN_PASSWORD after the database restore in $ENV_NAME"
            jem api apicall -s --connect-timeout 3 --max-time 15 [API_DOMAIN]/1.0/message/email/rest/send --data-urlencode "session=$USER_SESSION" --data-urlencode "to=$USER_EMAIL" --data-urlencode "subject=$SUBJECT" --data-urlencode "body=$BODY"
            if [[ $? != 0 ]]; then
                echo "Sending of e-mail notification failed"
            else
                echo "E-mail notification is sent successfully"
            fi
        elif [ -z "${CURRENT_PLATFORM_MAJOR_VERSION}" ]; then #this elif covers the case if the version is not received
            log "Error when checking the platform version"
        else
            echo "${EMAIL_ERROR_LOG_MESSAGE}";
        fi
     else
        echo "${EMAIL_ERROR_LOG_MESSAGE}";
     fi
} || {
   echo "[Info] User $user has the required access to the database."
}
