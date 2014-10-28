#!/bin/bash

# manage_pitr.sh - a base backup and wal archiving automation.
#
# Creates an archived base backup in a current date named directory in
# PITR_ARCHIVE_DIR, removes outdated base backup directories, in
# accordance with PITR_KEEP_DAYS, from PITR_ARCHIVE_DIR, and cleans
# WAL files, that are older than the oldest kept base backup, from
# PITR_WAL_ARCHIVE_DIR. If PITR_LOCAL_DIR is specified, it creates the
# base backup in this directory first and then RSYNC it to
# PITR_ARCHIVE_DIR. If PITR_WAL is set to true it starts a process of
# streaming WAL to PITR_WAL_ARCHIVE_DIR using PGRECEIVEXLOG. The
# streaming process is made for running as a cron job and exits
# normally if another instance is running with the same
# PITR_WAL_RECEIVER_LOCK_FILE.
#
# Copyright (c) 2014 Sergey Konoplev
#
# Sergey Konoplev <gray.ru@gmail.com>

source $(dirname $0)/config.sh
source $(dirname $0)/utils.sh

if $PITR_WAL; then
    error=$(mkdir -p $PITR_WAL_ARCHIVE_DIR 2>&1) || \
        die "Can not make wal directory $PITR_WAL_ARCHIVE_DIR: $error."

    (
        flock -xn 544 || exit 0
        error=$($PGRECEIVEXLOG -n -D $PITR_WAL_ARCHIVE_DIR 2>&1) || \
            die "Problem occured during WAL archiving: $error."
    ) 544>$PITR_WAL_RECEIVER_LOCK_FILE
else
    if [ -z "$PITR_LOCAL_DIR" ]; then
        PITR_LOCAL_DIR=$PITR_ARCHIVE_DIR
    fi

    backup_dir=$(date +%Y%m%d)

    error=$(mkdir -p $PITR_ARCHIVE_DIR 2>&1) || \
        die "Can not make archive directory: $error."

    error=$(mkdir -p $PITR_LOCAL_DIR/$backup_dir 2>&1) || \
        die "Can not make directory $backup_dir locally: $error."

    error=$($PGBASEBACKUP -F t -Z 2 -c fast \
                          -D $PITR_LOCAL_DIR/$backup_dir 2>&1) || \
        die "Can not make base backup: $error."

    info "Base backup $backup_dir has been made."

    if [ $PITR_ARCHIVE_DIR != $PITR_LOCAL_DIR ]; then
        error=$($RSYNC $PITR_LOCAL_DIR/$backup_dir $PITR_ARCHIVE_DIR 2>&1) || \
            die "Can not move base backup to archive: $error."
        error=$(rm -r $PITR_LOCAL_DIR/$backup_dir 2>&1) || \
            die "Can not clean base backup locally: $error."

        info "Base backup $backup_dir has been archived."
    fi

    keep_list=$( \
        (ls -1t $PITR_ARCHIVE_DIR | head -n $PITR_KEEP_BACKUPS) 2>&1) || \
        die "Can not get a list of base backups to keep: $keep_list."

    for dir in $(ls -1 $PITR_ARCHIVE_DIR); do
        if ! contains "$keep_list" $dir; then
            error=$(rm -r $PITR_ARCHIVE_DIR/$dir 2>&1) || \
                die "Can not remove obsolete base backup $dir: $error."

            info "Obsolete base backup $dir has been removed."
        fi
    done

    oldest=$((ls -1t $PITR_ARCHIVE_DIR | tail -n 1) 2>&1) || \
        die "Can not find the oldest base backup: $oldest."

    error=$( \
        find $PITR_WAL_ARCHIVE_DIR -ignore_readdir_race -type f ! -cnewer \
        $PITR_ARCHIVE_DIR/$oldest -delete 2>&1) || \
        die "Can not delete old WAL files from archive: $error."

    info "Obsolete WAL files have been cleaned."
fi
