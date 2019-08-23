#!/bin/bash

set -o nounset
#set -o errexit
set -o pipefail

BUCKET='timothymoll.zfs.backups'
AWS_REGION='eu-north-1'
BACKUP_PATH=$(hostname -f)

#SNAPSHOT_TYPES="zfs-auto-snap_frequent\|zfs-auto-snap_hourly\|zfs-auto-snap_daily\|zfs-auto-snap_weekly\|zfs-auto-snap_monthly"
SNAPSHOT_TYPES="zfs-auto-snap_monthly"

MAX_INCREMENTAL_BACKUPS=100
INCREMENTAL_FROM_INCREMENTAL=1

OPT_CONFIG_FILE='s3backup.conf'
OPT_DEBUG=""
OPT_PREFIX="zfs-backup"
OPT_QUIET=""
OPT_SYSLOG=""
OPT_VERBOSE=""

function print_usage
{
    echo "Usage: $0 [options] 
  -d, --debug        Print debugging messages
  -c, --config=FILE  Get config from FILE
  -h, --help         Print this usage message
  -q, --quiet        Suppress warnings and notices at the console
  -g, --syslog       Write messages into the system log
  -v, --verbose      Print info messages
" 
}

function check_set
{
    if [[ -z $2 ]]
    then
        print_log critical $1
        exit 1
    fi  
}

function print_log # level, message, ...
{
    local level=$1
    shift 1

    case $level in
        (eme*)
            test -n "$OPT_SYSLOG" && logger -t "$OPT_PREFIX" -p daemon.emerge $*
            echo Emergency: $* 1>&2
            ;;
        (ale*)
            test -n "$OPT_SYSLOG" && logger -t "$OPT_PREFIX" -p daemon.alert $*
            echo Alert: $* 1>&2
            ;;
        (cri*)
            test -n "$OPT_SYSLOG" && logger -t "$OPT_PREFIX" -p daemon.crit $*
            echo Critical: $* 1>&2
            ;;
        (err*)
            test -n "$OPT_SYSLOG" && logger -t "$OPT_PREFIX" -p daemon.err $*
            echo Error: $* 1>&2
            ;;
        (war*)
            test -n "$OPT_SYSLOG" && logger -t "$OPT_PREFIX" -p daemon.warning $*
            test -z "$OPT_QUIET" && echo Warning: $* 1>&2
            ;;
        (not*)
            test -n "$OPT_SYSLOG" && logger -t "$OPT_PREFIX" -p daemon.notice $*
            test -z "$OPT_QUIET" && echo $*
            ;;
        (inf*)
            test -n "$OPT_SYSLOG" && logger -t "$OPT_PREFIX" -p daemon.info $*
            test -z ${OPT_QUIET} && test -n "$OPT_VERBOSE" && echo $*
            ;;
        (deb*)
            # test -n "$OPT_SYSLOG" && logger -t "$OPT_PREFIX" -p daemon.debug $*
            test -n "$OPT_DEBUG" && echo Debug: $*
            ;;
        (*)
            test -n "$OPT_SYSLOG" && logger -t "$OPT_PREFIX" $*
            echo $* 1>&2
            ;;
    esac
}

function check_aws_bucket
{
    print_log debug "Starting check that AWS bucket exists"
    check_set "Missing bucket name" $BUCKET
    local bucket_ls=$( aws s3 ls $BUCKET 2>&1 )
    if [[ $bucket_ls =~ 'An error occurred (AccessDenied)' ]]
    then
        print_log error "Access denied attempting to access bucket $BUCKET"
        exit
    elif [[ $bucket_ls =~ 'An error occurred (NoSuchBucket)' ]]
    then
        print_log notice "Creating bucket $BUCKET in region $AWS_REGION"
        aws s3api create-bucket  --bucket $BUCKET --region $AWS_REGION --create-bucket-configuration LocationConstraint=$AWS_REGION --acl private
        aws s3api put-bucket-encryption --bucket $BUCKET --server-side-encryption-configuration '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}'
    else
        print_log info "Bucket \"$BUCKET\" exists and we have access to it"
    fi
}

function check_aws_folder
{
    local backup_path=${1-NO_DATASET}
    local dir_list=$(aws s3 ls $BUCKET/$backup_path 2>&1)
    if [[ $dir_list =~ 'An error occurred (AccessDenied)' ]]
    then
        print_log error "Access denied attempting to access $backup_path"
        exit
    elif [[ $dir_list == '' ]]
    then
        print_log notice "Creating remote folder $backup_path"
        aws s3api put-object --bucket $BUCKET --key $backup_path/
    fi
}

function incremental_backup
{
    local snapshot=${1-}
    local backup_path=${2-}
    local filename=${3-}
    local last_full_snapshot=${4-}
    local last_full_snapshot_file=${5-}
    local increment_from=${6-}
    local increment_from_file=${7-}
    local backup_seq=${8-}

    local snapshot_size=$( /sbin/zfs send --raw --nvPDci $increment_from $snapshot | awk '/size/ {print $2}' )

    print_log notice "Performing incremental backup of $snapshot from $increment_from ($snapshot_size bytes)"

    echo "/sbin/zfs send --raw -Dcpi $increment_from $snapshot | pv -s $snapshot_size | aws s3 cp - s3://$BUCKET/$backup_path/$filename \
        --expected-size $snapshot_size \
        --metadata=FullSnapshot=false,\
Snapshot=$snapshot,\
LastFullSnapshot=$last_full_snapshot,\
LastFullSnapshotFile=$last_full_snapshot_file,\
IncrementFrom=$increment_from,\
IncrementFromFile=$increment_from_file,\
BackupSeq=$backup_seq,\
Dedup=true,Lz4comp=true  "
}

function full_backup
{
    local snapshot=${1-}
    local backup_path=${2-}
    local filename=${3-}

    local snapshot_size=$( /sbin/zfs send --raw -nvPDc $snapshot |  awk '/size/ {print $2}' )

    print_log notice "Performing full backup of $snapshot ($snapshot_size bytes)"

    echo "/sbin/zfs send --raw -Dcp $snapshot | pv -s $snapshot_size | aws s3 cp - s3://$BUCKET/$backup_path/$filename \
        --expected-size $snapshot_size \
        --metadata=FullSnapshot=true,\
Snapshot=$snapshot,\
LastFullSnapshot=$snapshot,\
LastFullSnapshotFile=$filename,\
IncrementFrom=$snapshot,\
IncrementFromFile=$filename,\
BackupSeq=0,\
Dedup=true,Lz4comp=true "
}

function backup_dataset
{
    local dataset=${1-}
    check_set "Missing dataset name" $dataset
    local backup_path="$BACKUP_PATH/$dataset" 
    check_aws_folder $backup_path

    local latest_remote_file=$( aws s3 ls $BUCKET/$backup_path/ | grep -v \/\$ | sort  -r | head -1 | awk '{print $4}' )
    local latest_snapshot=$( /sbin/zfs list -Ht snap -o name,creation -p |grep "^$dataset@"| grep $SNAPSHOT_TYPES | sort -n -k2 | tail -1 | awk '{print $1}' )
    local remote_filename=$( echo $latest_snapshot | sed 's/\//./g' )

    if [[ -z $latest_snapshot ]]
    then
        print_log error "No snapshots found for $dataset"
    elif [[ -z $latest_remote_file ]]
    then
        print_log info "No remote file for $dataset found" 
        full_backup $latest_snapshot $backup_path $remote_filename
    elif [[ $latest_remote_file == $remote_filename ]]
    then
        print_log notice "$dataset remote backup is already at current version ($latest_snapshot)"
    else
        local remote_meta=$( aws s3api head-object --bucket $BUCKET --key $backup_path/$latest_remote_file )
        local last_full=$(echo $remote_meta| jq -r ".Metadata.lastfullsnapshot")
        local last_full_filename=$(echo $remote_meta| jq -r ".Metadata.lastfullsnapshotfile")
        local backup_seq=$(( $(echo $remote_meta | jq -r ".Metadata.backupseq" ) + 1 ))
        local increment_from=$(echo $remote_meta | jq -r ".Metadata.snapshot")
        local increment_from_filename=$latest_remote_file

        if [[ $INCREMENTAL_FROM_INCREMENTAL -ne 1 ]]
        then
            print_log info "Incremental incrementals turned off"
            increment_from=$last_full
            increment_from_filename=$last_full_filename
        elif [[ -z $( /sbin/zfs list -Ht snap -o name  | grep "^$increment_from$" )  ]]
        then
            print_log error "Previous snapshot missing ($increment_from) for $dataset reverting to last known full snapshot"
            increment_from=$last_full
            increment_from_filename=$last_full_filename
        fi

        if [[ $backup_seq -gt $MAX_INCREMENTAL_BACKUPS ]]
        then
            print_log notice "Max number of incrementals reached for $dataset"
            full_backup $latest_snapshot $backup_path $remote_filename
        elif [[ -z $( /sbin/zfs list -Ht snap -o name  | grep "^$increment_from$" ) ]]
        then
            print_log error "Previous full snapshot ($increment_from) missing, reverting to full snapshot"
            full_backup $latest_snapshot $backup_path $remote_filename
        else
            incremental_backup $latest_snapshot $backup_path $remote_filename $last_full $last_full_filename $increment_from $increment_from_filename $backup_seq
        fi
    fi 
}

GETOPT=$(getopt \
  --longoptions=config:,debug,help,quiet,syslog,verbose \
  --options=c:dhqsv \
  -- "$@" ) \
  || exit 128

eval set -- "$GETOPT"

while [ "$#" -gt '0' ]
do
    case "$1" in
        (-c|--config)
            OPT_CONFIG_FILE=$2
            shift 2
            ;;
        (-d|--debug)
            OPT_DEBUG='1'
            OPT_QUIET=''
            OPT_VERBOSE='1'
            shift 1
            ;;
        (-h|--help)
            print_usage
            exit 0
            ;;
        (-q|--quiet)
            OPT_DEBUG=''
            OPT_QUIET='1'
            OPT_VERBOSE=''
            shift 1
            ;;
        (-s|--syslog)
            OPT_SYSLOG='1'
            shift 1
            ;;
        (-v|--verbose)
            OPT_QUIET=''
            OPT_VERBOSE='1'
            shift 1
            ;;
        (--)
            shift 1
            break
            ;;
    esac
done

check_aws_bucket

for dataset in $( IFS=$'\n' ; cat $OPT_CONFIG_FILE)
do
    if [[ -z $( /sbin/zfs list -Ho name | grep "^$dataset$" ) ]]
    then
        print_log error "Requested dataset $dataset from $OPT_CONFIG_FILE does not exist"
    else
        print_log info ""
        print_log info "Processing dataset $dataset"
        backup_dataset $dataset
    fi
done

