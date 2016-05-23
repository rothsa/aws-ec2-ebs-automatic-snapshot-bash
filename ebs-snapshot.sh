#!/bin/bash
export PATH=$PATH:/usr/local/bin/:/usr/bin

# Safety feature: exit script if error is returned, or if variables not set.
# Exit if a pipeline results in an error.
set -ue
set -o pipefail

## Automatic EBS Volume Encrypted Snapshot Creation
# Written by Sally Lehman
# Additonal credits: Casey Labs; Log function by Alan Franzoni; Pre-req check by Colin Johnson
#
# PURPOSE: This Bash script can be used to take automatic snapshots of your Linux EC2 instance. Script process:
# - Determine the instance ID of the EC2 server on which the script runs
# - Gather a list of all volume IDs attached to that instance
# - Take a snapshot of each attached volume
# - Copy snapshot into an encrypted snapsnot
# - Delete Unencrypted Snapshot
#
# DISCLAIMER: This script deletes snapshots (though only the ones that it creates).
# Make sure that you understand how the script works. No responsibility accepted in event of accidental data loss.
#


## Variable Declarations ##

# Get Instance Details
instance_id=$(wget -q -O- http://169.254.169.254/latest/meta-data/instance-id)
region=$(wget -q -O- http://169.254.169.254/latest/meta-data/placement/availability-zone | sed -e 's/\([1-9]\).$/\1/g')

# Set Logging Options
logfile="/var/log/ebs-snapshot.log"
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

# Function: Snapshot all volumes attached to this instance.
snapshot_volumes() {
    for volume_id in $volume_list; do
        log "Volume ID is $volume_id"

    	# Get the attached device name to add to the description so we can easily tell which volume this is.
    	device_name=$(aws ec2 describe-volumes --region $region --output=text --volume-ids $volume_id --query 'Volumes[0].{Devices:Attachments[0].Device}')
    	# Take a snapshot of the current volume, and capture the resulting snapshot ID
    	snapshot_description="$(hostname)-$device_name-backup-$(date +%Y-%m-%d)"
    	unencrypted_snapshot_id=$(aws ec2 create-snapshot --region $region --output=text --description $snapshot_description --volume-id $volume_id --query SnapshotId)
    	unencrypted_state=$(aws ec2 describe-snapshots --snapshot-id $unencrypted_snapshot_id --query Snapshots[].State)
    	log "Unencrypted snapshot state: $unencrypted_state"
    	while (( $SECONDS < 60 )) && ! [[ $unencrypted_state == "completed" ]]; do
        	sleep 30;
        	state=$(aws ec2 describe-snapshots --snapshot-id $unencrypted_snapshot_id --query Snapshots[].State)
        	log "Unencrypted snapshot state: $unencrypted_state"
    	done

     	encrypt_snapshot

        # Cleanup unencrypted snapshot
        log "Deleting unencrypted snapshot $unencrypted_snapshot_id"
        aws --region $region ec2 delete-snapshot --snapshot-id $unencrypted_snapshot_id
	done
}

encrypt_snapshot() {
    #Take a copy of the snapshot and encrypt it with Amazon's CMK key
    snapshot_id=$(aws --region $region ec2 copy-snapshot --output=text  --source-region $region --source-snapshot-id $unencrypted_snapshot_id --encrypted  --description $snapshot_description)

    encrypted_state=$(aws ec2 describe-snapshots --snapshot-id $snapshot_id --query Snapshots[].State)
    log "Encrypted snapshot $snapshot_id state: $encrypted_state"
    while (( $SECONDS < 180 )) && ! [[ $encrypted_state == "completed" ]]; do
        sleep 30;
        encrypted_state=$(aws ec2 describe-snapshots --snapshot-id $snapshot_id --query Snapshots[].State)
        log "Encrypted snapshot $snapshot_id state: $encrypted_state"
    done
}

## SCRIPT COMMANDS ##

log_setup
prerequisite_check

# Grab all volume IDs attached to this instance
volume_list=$(aws ec2 describe-volumes --region $region --filters Name=attachment.instance-id,Values=$instance_id Name=attachment.device,Values=$device_id --query Volumes[].VolumeId --output text)

snapshot_volumes
