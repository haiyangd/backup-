#!/usr/bin/env bash

# Ensure that all possible binary paths are checked
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin

#Directory the script is in (for later use)
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Provides the 'log' command to simultaneously log to
# STDOUT and the log file with a single command
# NOTE: Use "" rather than \n unless you want a COMPLETELY blank line (no timestamp)
log() {
    echo -e "$(date -u +%Y-%m-%d-%H%M)" "$1" >> "${LOGFILE}"
    if [ "$2" != "noecho" ]; then
        echo -e "$1"
    fi
}


### LOAD IN CONFIG ###

# Prepare "new" settings that might not be in backup.cfg
SCPLIMIT=0

# Default config location
CONFIG="${SCRIPTDIR}"/backup.cfg

if [ "$1" == "--config" ]; then
    # Get config from specified file
    CONFIG="$2"
elif [ $# != 0 ]; then
    # Invalid arguments
    echo "Usage: $0 [--config filename]"
    exit
fi

# Check config file exists
if [ ! -e "${CONFIG}" ]; then
    echo "Couldn't find config file: ${CONFIG}"
    exit
fi

# Load in config
#CONFIG=$( realpath "${CONFIG}" )
. "${CONFIG}"

### END OF CONFIG ###

### CHECKS ###

# This section checks for all of the binaries used in the backup
BINARIES=( cat cd command date dirname echo find openssl pwd rm rsync scp ssh tar )

# Iterate over the list of binaries, and if one isn't found, abort
for BINARY in "${BINARIES[@]}"; do
    if [ ! "$(command -v "$BINARY")" ]; then
        log "$BINARY is not installed. Install it and try again"
        exit
    fi
done

# Check if the backup folders exist and are writeable
if [ ! -w "${LOCALDIR}" ]; then
    log "${LOCALDIR} either doesn't exist or isn't writable"
    log "Either fix or replace the LOCALDIR setting"
    exit
elif [ ! -w "${TEMPDIR}" ]; then
    log "${TEMPDIR} either doesn't exist or isn't writable"
    log "Either fix or replace the TEMPDIR setting"
    exit
fi

# Check that SSH login to remote server is successful
if [ ! "$(ssh -oBatchMode=yes -p "${REMOTEPORT}" "${REMOTEUSER}"@"${REMOTESERVER}" echo test)" ]; then
    log "Failed to login to ${REMOTEUSER}@${REMOTESERVER}"
    log "Make sure that your public key is in their authorized_keys"
    exit
fi

# Check that remote directory exists and is writeable
if ! ssh -p "${REMOTEPORT}" "${REMOTEUSER}"@"${REMOTESERVER}" test -w "${REMOTEDIR}" ; then
    log "Failed to write to ${REMOTEDIR} on ${REMOTESERVER}"
    log "Check file permissions and that ${REMOTEDIR} is correct"
    exit
fi

BACKUPDATE=$(date -u +%Y-%m-%d-%H%M)
STARTTIME=$(date +%s)
TARFILE="${LOCALDIR}""$(hostname)"-"${BACKUPDATE}".tar.gz
SQLFILE="${TEMPDIR}mysql_${BACKUPDATE}.sql"

cd "${LOCALDIR}" || exit

### END OF CHECKS ###

### MYSQL BACKUP ###

if [ ! "$(command -v mysqldump)" ]; then
    log "mysqldump not found, not backing up MySQL!"
elif [ -z "$ROOTMYSQL" ]; then
    log "MySQL root password not set, not backing up MySQL!"
else
    log "Starting MySQL dump dated ${BACKUPDATE}"
    mysqldump -u root -p"${ROOTMYSQL}" --all-databases > "${SQLFILE}"
    log "MySQL dump complete"; log ""

    #Add MySQL backup to BACKUP list
    BACKUP=(${BACKUP[*]} ${SQLFILE})
fi

### END OF MYSQL BACKUP ###

### TAR BACKUP ###

log "Starting tar backup dated ${BACKUPDATE}"
# Prepare tar command
TARCMD="-zcvf ${TARFILE} ${BACKUP[*]}"

# Check if there are any exclusions
if [[ "x${EXCLUDE[@]}" != "x" ]]; then
    # Add exclusions to front of command
    for i in "${EXCLUDE[@]}"; do
        TARCMD="--exclude $i ${TARCMD}"
    done
fi

# Run tar
tar ${TARCMD}

# Encrypt tar file
log "Encrypting backup"
openssl enc -e -aes-256-cbc  -in "${TARFILE}" -out "${TARFILE}".enc -pass pass:"${BACKUPPASS}" -md sha1
log "Encryption completed"

# Delete unencrypted tar
rm "${TARFILE}"

BACKUPSIZE=$(du -h "${TARFILE}".enc | cut -f1)
log "Tar backup complete. Filesize: ${BACKUPSIZE}"; log ""

# Transfer to remote server
log "Tranferring tar backup to remote server"

# Check if bandwidth limiting is enabled
if [ "${SCPLIMIT}" -gt 0 ]; then 
    scp -l "${SCPLIMIT}" -P "${REMOTEPORT}" "${TARFILE}".enc "${REMOTEUSER}"@"${REMOTESERVER}":"${REMOTEDIR}"
else
    scp -P "${REMOTEPORT}" "${TARFILE}".enc "${REMOTEUSER}"@"${REMOTESERVER}":"${REMOTEDIR}"
fi
log "File transfer completed"; log ""

if [ "$(command -v mysqldump)" ]; then
    if [ ! -z "${ROOTMYSQL}" ]; then
        log "Deleting temporary MySQL backup"; log ""
        rm "${SQLFILE}"
    fi
fi

### END OF TAR BACKUP ###

### RSYNC BACKUP ###

log "Starting rsync backups"
for i in "${RSYNCDIR[@]}"; do
    rsync -aqz --no-links --progress --delete --relative -e"ssh -p ${REMOTEPORT}" "$i" "${REMOTEUSER}"@"${REMOTESERVER}":"${REMOTEDIR}"
done
log "rsync backups complete"; log ""

### END OF RSYNC BACKUP ###

### BACKUP DELETION ##

log "Checking for LOCAL backups to delete..."
bash "${SCRIPTDIR}"/deleteoldbackups.sh --config "${CONFIG}"
log ""

log "Checking for REMOTE backups to delete..."
bash "${SCRIPTDIR}"/deleteoldbackups.sh --config "${CONFIG}" --remote
log ""

### END OF BACKUP DELETION ###

ENDTIME=$(date +%s)
DURATION=$((ENDTIME - STARTTIME))
log "All done. Backup and transfer completed in ${DURATION} seconds\n"
