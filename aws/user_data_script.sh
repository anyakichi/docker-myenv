#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

DIN_OPTS=(
    -e TERM=screen-256color
    -e YOCTO_DL_DIR=/cache/yocto/downloads
    -e YOCTO_SSTATE_DIR=/cache/s3/yocto/sstate
    -v /data/cache:/cache
)

MYENV_OPTS=(
    --name myenv
    -d
    -e TERM=tmux-256color
    -v /var/run/docker.sock:/var/run/docker.sock
)

export AWS_DEFAULT_REGION
AWS_DEFAULT_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
INSTANCE_AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)

FLEET_REQUEST_ID=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query "Reservations[].Instances[].Tags[?Key=='aws:ec2spot:fleet-request-id'].Value" \
    --output text)

get_tag_value() {
    local result

    result=$(aws ec2 describe-spot-fleet-requests \
        --spot-fleet-request-ids "$FLEET_REQUEST_ID" \
        --query "SpotFleetRequestConfigs[].Tags[?Key=='$1'].Value" \
        --output text)
    if [[ $result ]]; then
        echo "$result"
        return 0
    fi

    result=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
        --query "Reservations[].Instances[].Tags[?Key=='$1'].Value" \
        --output text)
    if [[ $result ]]; then
        echo "$result"
        return 0
    fi
}

BUILDDIR=$(get_tag_value builddir)
BUILDENV=$(get_tag_value buildenv)
EBS_CACHE_NAME=$(get_tag_value ebs_cache_name)
EBS_CACHE_SIZE=$(get_tag_value ebs_cache_size)
EBS_DATA_NAME=$(get_tag_value ebs_data_name)
EBS_DATA_SIZE=$(get_tag_value ebs_data_size)
MYENV=$(get_tag_value myenv)
S3_BUCKET=$(get_tag_value s3_bucket)

setup_user() {
    cat <<EOS >>~ec2-user/.bashrc
alias din='din ${DIN_OPTS[@]}'

buildenv() {
    if [[ -z "\$(docker ps -q --filter "name=^buildenv$")" ]]; then
        din --name buildenv -d "\$@" $BUILDENV
    fi
    docker attach buildenv
}

myenv() {
    if [[ -z "\$(docker ps -q --filter "name=^myenv$")" ]]; then
        command din ${MYENV_OPTS[@]} "\$@" $MYENV
    fi
    docker attach myenv
}
EOS

    mkdir ~ec2-user/.docker
    echo '{"detachKeys": "ctrl-\\,ctrl-x"}' >~ec2-user/.docker/config.json
    chown ec2-user: ~ec2-user/.docker
}

mount_ebs() {
    local args device name path snapshot_id volume_id

    name="$1"
    size="$2"
    device="$3"
    path="$4"

    volume_id=$(aws ec2 describe-volumes \
        --filter "Name=tag:Name,Values=$name" \
        --query "Volumes[].VolumeId" --output text)
    if [ -n "$volume_id" ]; then
        # Shutdown if data volume already exists.  Another VM might exist.
        poweroff
    fi

    # Get the latest snapshot ID.
    snapshot_id=$(aws ec2 describe-snapshots --owner-ids self \
        --filter "Name=tag:Name,Values=$name" \
        --query "reverse(sort_by(Snapshots,&StartTime))[0].SnapshotId" \
        --output text)

    args=()
    if [[ $snapshot_id != None ]]; then
        args+=(--snapshot-id "$snapshot_id")
    fi
    volume_id=$(aws ec2 create-volume --availability-zone "$INSTANCE_AZ" \
        --volume-type gp3 --size "$size" \
        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$name}]" \
        --query VolumeId --output text ${args[@]+"${args[@]}"})

    aws ec2 wait volume-available --volume-id "$volume_id"
    aws ec2 attach-volume --volume-id "$volume_id" \
        --instance-id "$INSTANCE_ID" --device "$device"

    while true; do
        if [[ -e $device ]]; then
            break
        fi
        sleep 1
    done

    mkdir -p /data
    if [[ $snapshot_id == None ]]; then
        mkfs.ext4 "$device"
    fi
    mount "$device" "$path"
}

mount_buildenv_data() {
    mount_ebs "$EBS_DATA_NAME" "$EBS_DATA_SIZE" /dev/sdf /data
    mkdir -p /data/cache /data/tmp
    chown ec2-user: /data /data/cache /data/tmp
}

mount_buildenv_cache() {
    if [[ -n $EBS_CACHE_NAME ]]; then
        mount_ebs "$EBS_CACHE_NAME" "$EBS_CACHE_SIZE" /dev/sdg /data/cache
        chown ec2-user: /data/cache
    fi
}

mount_buildenv_cache_s3() {
    if [[ -n $S3_BUCKET ]]; then
        mkdir -p /data/cache/s3
        s3fs "$S3_BUCKET" /data/cache/s3 \
            -o uid=1000,gid=1000,allow_other,iam_role=auto \
            -o use_cache=/data/tmp,del_cache \
            -o url="https://s3-us-west-2.amazonaws.com"
    fi
}

install_package() {
    yum update -y
    amazon-linux-extras install docker
    mkdir -p /etc/systemd/system/docker.socket.d
    printf "[Socket]\nSocketGroup=ec2-user" \
        >/etc/systemd/system/docker.socket.d/override.conf
    systemctl daemon-reload
    service docker start

    amazon-linux-extras install epel
    yum install -y s3fs-fuse
}

install_din() {
    curl -LsS -o /usr/local/bin/din \
        https://raw.githubusercontent.com/anyakichi/docker-buildenv/master/din.sh
    chmod +x /usr/local/bin/din
}

buildenv() {
    (cd "/data/$BUILDDIR" &&
        din --name buildenv -d "${DIN_OPTS[@]}" "$BUILDENV" "$@")
    docker logs -f buildenv
    docker wait buildenv || ture
}

install_din &
install_package &
mount_buildenv_data &
setup_user &

wait

if [[ -n $BUILDENV ]]; then
    docker pull "$BUILDENV" &
fi

if [[ -n $MYENV ]]; then
    docker pull "$MYENV" &
fi

mount_buildenv_cache
mount_buildenv_cache_s3

wait

if [[ -n $BUILDENV && -n $BUILDDIR ]]; then
    if [[ ! -d "/data/$BUILDDIR" ]]; then
        mkdir "/data/$BUILDDIR"
        chown ec2-user: "/data/$BUILDDIR"
        buildenv extract -y
    fi
    buildenv build -y

    poweroff
fi
