#!/bin/bash

BASE_URL=$2
BACKUP_TYPE=$3
NODE_ID=$4
BACKUP_LOG_FILE=$5
ENV_NAME=$6
BACKUP_COUNT=$7
DBUSER=$8
DBPASSWD=$9
USER_SESSION=${10}
USER_EMAIL=${11}

BACKUP_ADDON_REPO=$(echo ${BASE_URL}|sed 's|https:\/\/raw.githubusercontent.com\/||'|awk -F / '{print $1"/"$2}')
BACKUP_ADDON_BRANCH=$(echo ${BASE_URL}|sed 's|https:\/\/raw.githubusercontent.com\/||'|awk -F / '{print $3}')
BACKUP_ADDON_COMMIT_ID=$(git ls-remote https://github.com/${BACKUP_ADDON_REPO}.git | grep "/${BACKUP_ADDON_BRANCH}$" | awk '{print $1}')

if which restic; then
    true
else
    if which dnf 2>&1; then
          dnf install -y epel-release 2>&1
          dnf install -y restic 2>&1
    else
          yum-config-manager --disable nodesource 2>&1
          yum-config-manager --add-repo https://copr.fedorainfracloud.org/coprs/copart/restic/repo/epel-7/copart-restic-epel-7.repo 2>&1
          yum-config-manager --enable copr:copr.fedorainfracloud.org:copart:restic 2>&1
          yum -y install restic 2>&1
          yum-config-manager --disable copr:copr.fedorainfracloud.org:copart:restic 2>&1
    fi 
fi

if grep -q '^replication' /etc/mongod.conf; then
    MONGO_TYPE="-replica-set"
else
    MONGO_TYPE="-standalone"
fi

source /etc/jelastic/metainf.conf;

function sendEmailNotification(){
    if [ -e "/usr/lib/jelastic/modules/api.module" ]; then
        [ -e "/var/run/jem.pid" ] && return 0;
        CURRENT_PLATFORM_MAJOR_VERSION=$(jem api apicall -s --connect-timeout 3 --max-time 15 [API_DOMAIN]/1.0/statistic/system/rest/getversion 2>/dev/null |jq .version|grep -o [0-9.]*|awk -F . '{print $1}')
        if [ "${CURRENT_PLATFORM_MAJOR_VERSION}" -ge "7" ]; then
            echo $(date) ${ENV_NAME} "Sending e-mail notification about removing the stale lock" | tee -a $BACKUP_LOG_FILE;
            SUBJECT="Stale lock is removed on /opt/backup/${ENV_NAME} backup repo"
            BODY="Please pay attention to /opt/backup/${ENV_NAME} backup repo because the stale lock left from previous operation is removed during the integrity check and backup rotation. Manual check of backup repo integrity and consistency is highly desired."
            jem api apicall -s --connect-timeout 3 --max-time 15 [API_DOMAIN]/1.0/message/email/rest/send --data-urlencode "session=$USER_SESSION" --data-urlencode "to=$USER_EMAIL" --data-urlencode "subject=$SUBJECT" --data-urlencode "body=$BODY"
            if [[ $? != 0 ]]; then
                echo $(date) ${ENV_NAME} "Sending of e-mail notification failed" | tee -a $BACKUP_LOG_FILE;
            else
                echo $(date) ${ENV_NAME} "E-mail notification is sent successfully" | tee -a $BACKUP_LOG_FILE;
            fi
        elif [ -z "${CURRENT_PLATFORM_MAJOR_VERSION}" ]; then #this elif covers the case if the version is not received
            echo $(date) ${ENV_NAME} "Error when checking the platform version" | tee -a $BACKUP_LOG_FILE;
        else
            echo $(date) ${ENV_NAME} "Email notification is not sent because this functionality is unavailable for current platform version." | tee -a $BACKUP_LOG_FILE;
        fi
    else
        echo $(date) ${ENV_NAME} "Email notification is not sent because this functionality is unavailable for current platform version." | tee -a $BACKUP_LOG_FILE;
    fi
}

function update_restic(){
    restic self-update 2>&1;
}

function check_backup_repo(){
    [ -d /opt/backup/${ENV_NAME} ] || mkdir -p /opt/backup/${ENV_NAME}
    export FILES_COUNT=$(ls -n /opt/backup/${ENV_NAME}|awk '{print $2}');
    if [ "${FILES_COUNT}" != "0" ]; then 
        echo $(date) ${ENV_NAME}  "Checking the backup repository integrity and consistency" | tee -a $BACKUP_LOG_FILE;
        if [[ $(ls -A /opt/backup/${ENV_NAME}/locks) ]] ; then
	    echo $(date) ${ENV_NAME}  "Backup repository has a slate lock, removing" | tee -a $BACKUP_LOG_FILE;
            GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -r /opt/backup/${ENV_NAME} unlock
	    sendEmailNotification
        fi
        GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -q -r /opt/backup/${ENV_NAME} check --read-data-subset=5% || { echo "Backup repository integrity check failed."; exit 1; }
    else
        GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic init -r /opt/backup/${ENV_NAME}
    fi
}

function rotate_snapshots(){
    echo $(date) ${ENV_NAME} "Rotating snapshots by keeping the last ${BACKUP_COUNT}" | tee -a ${BACKUP_LOG_FILE}
    if [[ $(ls -A /opt/backup/${ENV_NAME}/locks) ]] ; then
        echo $(date) ${ENV_NAME}  "Backup repository has a slate lock, removing" | tee -a $BACKUP_LOG_FILE;
        GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic -r /opt/backup/${ENV_NAME} unlock
	sendEmailNotification
    fi
    { GOGC=20 RESTIC_PASSWORD=${ENV_NAME} restic forget -q -r /opt/backup/${ENV_NAME} --keep-last ${BACKUP_COUNT} --prune | tee -a $BACKUP_LOG_FILE; } || { echo "Backup rotation failed."; exit 1; }
}

function create_snapshot(){
    source /etc/jelastic/metainf.conf 
    echo $(date) ${ENV_NAME} "Saving the DB dump to ${DUMP_NAME} snapshot" | tee -a ${BACKUP_LOG_FILE}
    DUMP_NAME=$(date "+%F_%H%M%S"-${BACKUP_TYPE}\($COMPUTE_TYPE-$COMPUTE_TYPE_FULL_VERSION$MONGO_TYPE\))
    GOGC=20 RESTIC_COMPRESSION=off RESTIC_PACK_SIZE=8 RESTIC_PASSWORD=${ENV_NAME} restic backup -q -r /opt/backup/${ENV_NAME} --tag "${DUMP_NAME} ${BACKUP_ADDON_COMMIT_ID} ${BACKUP_TYPE}" ~/dump | tee -a ${BACKUP_LOG_FILE}
}

function backup(){
    echo $$ > /var/run/${ENV_NAME}_backup.pid
    echo $(date) ${ENV_NAME} "Creating the ${BACKUP_TYPE} backup (using the backup addon with commit id ${BACKUP_ADDON_COMMIT_ID}) on storage node ${NODE_ID}" | tee -a ${BACKUP_LOG_FILE}
    source /etc/jelastic/metainf.conf;
    echo $(date) ${ENV_NAME} "Creating the DB dump" | tee -a ${BACKUP_LOG_FILE}
    if grep -q ^[[:space:]]*replSetName /etc/mongod.conf; then
        RS_NAME=$(grep ^[[:space:]]*replSetName /etc/mongod.conf|awk '{print $2}');
	RS_SUFFIX="/?replicaSet=${RS_NAME}&readPreference=nearest";
    else
        RS_SUFFIX="";
    fi
    mongodump -u ${DBUSER} -p ${DBPASSWD} --uri="mongo://localhost${RS_SUFFIX}" --authenticationDatabase=admin
    rm -f /var/run/${ENV_NAME}_backup.pid
}

case "$1" in
    backup)
        $1
        ;;
    check_backup_repo)
        $1
        ;;
    rotate_snapshots)
        $1
        ;;
    create_snapshot)
	$1
	;;
     update_restic)
	$1
        ;;
    *)
        echo "Usage: $0 {backup|check_backup_repo|rotate_snapshots|create_snapshot|update_restic}"
        exit 2
esac

exit $?
