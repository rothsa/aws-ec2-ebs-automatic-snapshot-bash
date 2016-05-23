#!/bin/bash
export PATH=$PATH:/usr/local/bin/:/usr/bin

# Safety feature: exit script if error is returned, or if variables not set.
# Exit if a pipeline results in an error.
set -ue
set -o pipefail

## Automatic EBS Volume Snapshot Clean-Up Script
# Written by: Sally Lehman
# Additonal credits: Casey Labs;  Log function by Alan Franzoni; Pre-req check by Colin Johnson
#
# PURPOSE: This Bash script cleans up old and unencrypted automatic snapshots of your Linux EC2 instance. Script process:
# - Determine the instance ID of the EC2 server on which the script runs using the snapshot description
# - The script will then delete all associated snapshots taken by the script that are older than 7 days
# - The script will also delete all snapshots that are unencrypted
#
# DISCLAIMER: This script deletes snapshots, including ALL UNENCRYPTED SNAPSHOTS for the instance it's running on.
# Make sure that you understand how the script works. No responsibility accepted in event of accidental data loss.
#


## Variable Declartions ##

# Get Instance Details
instance_id=$(wget -q -O- http://169.254.169.254/latest/meta-data/instance-id)
region=$(wget -q -O- http://169.254.169.254/latest/meta-data/placement/availability-zone | sed -e 's/\([1-9]\).$/\1/g')

# Set Logging Options
logfile="/var/log/ebs-snapshot-cleanup.log"
logfile_max_lines="5000"

# How many days do you wish to retain backups for? Default: 7 days
retention_days="7"
retention_date_in_seconds=$(date +%s --date "$retention_days days ago")

# Mongo DB data folder associated device
device_id="/dev/xvdf"

## Function Declarations ##

# Function: Setup logfile and redirect stdout/stderr.
log_setup() {
    # Check if logfile exists and is writable.
    ( [ -e "$logfile" ] || touch "$logfile" ) && [ ! -w "$logfile" ] && echo "ERROR: Cannot write to $logfile. Check permissions or sudo access." && exit 1

    tmplog=$(tail -n $logfile_max_lines $logfile 2>/dev/null) && echo "${tmplog}" > $logfile
    exec > >(tee -a $logfile)
    exec 2>&1
}

# Function: Log an event.
log() {
    echo "[$(date +"%Y-%m-%d"+"%T")]: $*"
}

# Function: Confirm that the AWS CLI and related tools are installed.
prerequisite_check() {
    for prerequisite in aws wget; do
        hash $prerequisite &> /dev/null
        if [[ $? == 1 ]]; then
            echo "In order to use this script, the executable \"$prerequisite\" must be installed." 1>&2; exit 70
        fi
    done
}


# Function: Cleanup all unencrypted snapshots and snapshots 
# associated with this instance that are older than $retention_days
cleanup_snapshots() {
# Encrypted Backups lose their volume numbers, and tags sometimes fail to be created, so we're gonna use
# the owner and file description to ensure the volumes we're looking at are the right ones
    initial_snapshot_description="$(hostname)-$device_id-backup-*"
    snapshot_list=$(aws ec2 describe-snapshots --region $region --output=text --filters "Name=description,Values=$initial_snapshot_description" --query Snapshots[].SnapshotId)
    echo $snapshot_list
    for snapshot in $snapshot_list; do
        log "Checking $snapshot..."
        # Check age of snapshot
        snapshot_date=$(aws ec2 describe-snapshots --region $region --output=text --snapshot-ids $snapshot --query Snapshots[].StartTime | awk -F "T" '{printf "%s\n", $1}')
        snapshot_date_in_seconds=$(date "--date=$snapshot_date" +%s)
        snapshot_description=$(aws ec2 describe-snapshots --snapshot-id $snapshot --region $region --query Snapshots[].Description)
        snapshot_encryption_status=$(aws ec2 describe-snapshots --snapshot-id $snapshot --region $region --query Snapshots[].Encrypted)
        if (( $snapshot_date_in_seconds <= $retention_date_in_seconds )); then
            log "DELETING snapshot $snapshot because it is old. Description: $snapshot_description ..."
            aws ec2 delete-snapshot --region $region --snapshot-id $snapshot

        elif [[ $snapshot_encryption_status == "False" ]]; then
            log "DELETING snapshot $snapshot as it is unencrypted. Description: $snapshot_description ..."
            aws ec2 delete-snapshot --region $region --snapshot-id $snapshot
        else
            log "Not deleting snapshot $snapshot. Description: $snapshot_description ..."
        fi
    done
}


## SCRIPT COMMANDS ##

log_setup
prerequisite_check

cleanup_snapshots
