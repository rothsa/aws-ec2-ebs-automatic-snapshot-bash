#!/bin/bash
export PATH=$PATH:/usr/local/bin/:/usr/bin

# Safety feature: exit script if error is returned, or if variables not set.
# Exit if a pipeline results in an error.
set -ue
set -o pipefail

instance_id=$(wget -q -O- http://169.254.169.254/latest/meta-data/instance-id)
region=$(wget -q -O- http://169.254.169.254/latest/meta-data/placement/availability-zone | sed -e 's/\([1-9]\).$/\1/g')
availability_zone=$(wget -q -O- http://169.254.169.254/latest/meta-data/placement/availability-zone)

# Mongo DB data folder associated device
device_id="/dev/xvdf"

# Hostname from which the snapshots originated
snapshot_origin_hostname=ip-10-0-3-68

# Restore outside replica set
# Will reset the  Replica Set config for the host you are restoring to
# So that the DB will quickly be viewed. MUST BE FALSE for production
reset_replica_set_conf=true

# How old of a backup are you looking for? Default: 1 days
backup_age="1"
backup_age_in_seconds=$(date +%s --date "$backup_age days ago")

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

choose_snapshot() {
    initial_snapshot_description="$snapshot_origin_hostname-$device_id-backup-*"
    snapshot_list=$(aws ec2 describe-snapshots --region $region --output=text --filters "Name=description,Values=$initial_snapshot_description" --query Snapshots[].SnapshotId)
    log "Available snapshots to restore:  $snapshot_list"
    snapshot_to_restore=""
        until [ $snapshot_to_restore ]; do
            for snapshot in $snapshot_list; do
                log "Checking $snapshot..."
                # Check age of snapshot
                snapshot_date=$(aws ec2 describe-snapshots --region $region --output=text --snapshot-ids $snapshot --query Snapshots[].StartTime | awk -F "T" '{printf "%s\n", $1}')
                snapshot_date_in_seconds=$(date "--date=$snapshot_date" +%s)
                snapshot_description=$(aws ec2 describe-snapshots --snapshot-id $snapshot --region $region --query Snapshots[].Description)
                if (( $snapshot_date_in_seconds <= $backup_age_in_seconds )); then
                    snapshot_to_restore=$snapshot
                    log "Chosen Snapshot: $snapshot_description"
                fi
            done
        done
}

create_volume() {
    new_volume_id=$(aws ec2 create-volume --region $region --availability-zone $availability_zone --snapshot-id $snapshot_to_restore)
    log "New volume $new_volume_id created"
}

unmount_mongo_data() {
    # Shut down mongo and unmount the /data mounted device
    service mongod stop
    umount -d $device_id
    sleep 5;
    if grep -qs $device_id /proc/mounts; then
        log "Old device unmounted. Stopping Mongod"
    else
        log "Old device not mounted, exiting."
        exit
    fi
}

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

detach_old_data_volume() {
    # find old_volume_id
    old_volume_id=$(aws ec2 describe-volumes --region $region --filters Name-attachment.status,Values="attached" Name=attachment.instance-id,Values=$instance_id Name=attachment.device,Values=$device_id --query Volumes[].VolumeId --output text)
    log "Located attached volume $old_volume_id. Commencing to detach"
    detached_volume=$(aws ec2 detach-volume --instance-id $instance_id --device /dev/xvdf --volume-id $old_volume_id --region $region)
    log "Old volume $detached_volume detached"
    check_volume_attachment=$(aws ec2 describe-volumes --region $region --filters Name-attachment.status,Values="attached" Name=attachment.instance-id,Values=$instance_id Name=attachment.device,Values=$device_id --query Volumes[].VolumeId --output text)
    while ! [[ check_volume_attachment == "detached" ]]; do
            sleep 5;
            check_volume_attachment=$(aws ec2 describe-volumes --region $region --filters Name-attachment.status,Values="detached" Name=attachment.instance-id,Values=$instance_id Name=attachment.device,Values=$device_id --query Volumes[].VolumeId --output text)
    done
}

attach_new_data_volume() {
    log "Commencing to attach new volume $new_volume_id."
    attached_volume=$(aws ec2 attach-volume --instance-id $instance_id --device $device_id --volume-id $new_volume_id --region $region)
    check_volume_attachment=""
    while ! [[ check_volume_attachment ]]; do
        sleep 5;
        check_volume_attachment=$(aws ec2 describe-volumes --region $region --filters Name-attachment.status,Values="attached" Name=attachment.instance-id,Values=$instance_id Name=attachment.device,Values=$device_id --query Volumes[].VolumeId --output text)
    done
    log "New volume $attached_volume attached"
}

reset_replica_set_settings() {
    reset_query='use local;db.system.replset.remove( { _id : "s-1" } );rs.initiate({_id: "s-1",version: 1,members: [{ _id: 0, host : "localhost:27017" }]});'
    mongo admin --eval $reset_query
    check_query='use local;db.system.replset.find()'
    result=$(mongo admin --eval $reset_query)
    log "Attepted to reset replica set settings, Result: $result"
}

## SCRIPT COMMANDS ##

choose_snapshot
create_volume_from_snapshot
unmount_mongo_data
detach_old_data_volume
attach_new_data_volume
mount_mongo_data

if [[ reset_replica_set_conf == "true" ]]; then
    reset_replica_set_settings
    log "Replica settings reset, the DB should be ready to query and dump with"
fi
