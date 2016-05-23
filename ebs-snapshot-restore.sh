#!/bin/bash
export PATH=$PATH:/usr/local/bin/:/usr/bin

# Safety feature: exit script if error is returned, or if variables not set.
# Exit if a pipeline results in an error.
set -ue
set -o pipefail

# Get Instance Details
instance_id=$(wget -q -O- http://169.254.169.254/latest/meta-data/instance-id)
region=$(wget -q -O- http://169.254.169.254/latest/meta-data/placement/availability-zone | sed -e 's/\([1-9]\).$/\1/g')
availability_zone=$(wget -q -O- http://169.254.169.254/latest/meta-data/placement/availability-zone)

# Set Logging Options
logfile="/var/log/ebs-snapshot.log"
logfile_max_lines="5000"

# Mongo DB data folder associated device
device_id="/dev/xvdf"

# Hostname from which the snapshots originated
snapshot_origin_hostname=ip-10-0-3-68

# How old of a backup are you looking for? Default: 1 days
# This is just a placeholdern production this would probably be expanded to a date range
oldest_backup_age="1"
newest_backup_age="0"
oldest_backup_age_in_seconds=$(date +%s --date "$oldest_backup_age days ago")
newest_backup_age_in_seconds=$(date +%s --date "$newest_backup_age days ago")
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
# Function: Find snapshots matching description for the snapshot origin hostname and select the first one that is old enough to meet requirements.
choose_snapshot() {
    initial_snapshot_description="$snapshot_origin_hostname-$device_id-backup-*"
    snapshot_list=$(aws ec2 describe-snapshots --region $region --output=text --filters Name=description,Values=$initial_snapshot_description Name=status,Values='completed' --query Snapshots[].SnapshotId)
    log "Available snapshots to restore:  $snapshot_list"
    snapshot_to_restore=""
        for snapshot in $snapshot_list; do
            log "Checking $snapshot..."
            # Check age of snapshot
            snapshot_date=$(aws ec2 describe-snapshots --region $region --output=text --snapshot-ids $snapshot --query Snapshots[].StartTime | awk -F "T" '{printf "%s\n", $1}')
            snapshot_date_in_seconds=$(date "--date=$snapshot_date" +%s)
            snapshot_description=$(aws ec2 describe-snapshots --snapshot-id $snapshot --region $region --query Snapshots[].Description --output text)
            if (( $snapshot_date_in_seconds <= $newest_backup_age_in_seconds )) && (( $snapshot_date_in_seconds >= $oldest_backup_age_in_seconds )); then
                snapshot_to_restore=$snapshot
                log "Possible snapshot: $snapshot $snapshot_description"
            fi
        done

    log "Selected snapshot: $snapshot_to_restore"
}
# Function: This function creates a new EBS volume from the chosen backup snapshot
create_volume() {
    new_volume_id=$(aws ec2 create-volume --region $region --availability-zone $availability_zone --snapshot-id $snapshot_to_restore --query VolumeId --output text)
    log "New volume is $new_volume_id"
    check_volume_status=$(aws ec2 describe-volumes --region $region --volume-ids $new_volume_id --query Volumes[].State --output text)
    if ! [[ check_volume_status == "available" ]]; then
        sleep 10;
        check_volume_status=$(aws ec2 describe-volumes --region $region --volume-ids $new_volume_id --query Volumes[].State --output text)
    fi
    log "New Volume $new_volume_id $check_volume_status"
}

# Function: This function unmounts the block device for the old volume
unmount_mongo_data() {
    # Shut down mongo and unmount the /data mounted device
    service mongod stop
    umount -d $device_id
    sleep 5;
    if grep -qs $device_id /proc/mounts; then
        log "Old device not unmounted"
        exit
    else
        log "Old device unmounted"
    fi
}
# Function: This function ensures that /data is now accessible from the new volume
mount_mongo_data() {
#check unmounted
    mount /data
    sleep 5;
    #ensure mounted
    if grep -qs $device_id /proc/mounts; then
        log "New device mounted. Starting Mongod"
        service mongod start
    else
        log "New device not mounted, exiting."
        exit
    fi
}
# Function: This function detaches the existing EBS volume from this instance
detach_old_data_volume() {
    # find old_volume_id
    old_volume_id=$(aws ec2 describe-volumes --region $region --filters Name=attachment.status,Values="attached" Name=attachment.instance-id,Values=$instance_id Name=attachment.device,Values=$device_id --query Volumes[].VolumeId --output text)
    log "Located attached volume $old_volume_id. Commencing to detach"
    detached_volume_status=$(aws ec2 detach-volume --instance-id $instance_id --device $device_id --volume-id $old_volume_id --region $region --query State)
    log "$old_volume_id now is  $detached_volume_status"
    if ! [[ detached_volume_status == "available" ]]; then
        sleep 20;
        detached_volume_status=$(aws ec2 describe-volumes --region $region --volume-id $old_volume_id --query Volumes[].State --output text)
        log "$old_volume_id now is $detached_volume_status"
    else
        "Volume taking abnormal time to detach, exiting"
        exit
    fi
}
# Function: This function attaches the newly created EBS volume to this instance and block device
attach_new_data_volume() {
    log "Commencing to attach new volume $new_volume_id."
    attach_volume_status=$(aws ec2 attach-volume --instance-id $instance_id --device $device_id --volume-id $new_volume_id --region $region --query State)
    if ! [[ attach_volume_status == "in-use" ]]; then
        sleep 15;
        attach_volume_status=$(aws ec2 describe-volumes --region $region --volume-id $new_volume_id --query Volumes[].State --output text)
        log "$new_volume_id is now $attach_volume_status"
    else
        "Volume taking an abnormal amount of time to attach, exiting"
        exit
    fi
    log "New volume $new_volume_id $attach_volume_status"
}

## SCRIPT COMMANDS ##

log_setup
prerequisite_check
choose_snapshot
create_volume
unmount_mongo_data
detach_old_data_volume
attach_new_data_volume
mount_mongo_data

log "DB Restored and ready for use/dump"