#!/bin/bash

VOLUMES=(
    buildenv-cache
    buildenv-data
)

create_snapshot() {
    local name volume_id
    name="$1"

    volume_id=$(aws ec2 describe-volumes \
        --filter "Name=tag:Name,Values=$name" \
        --query "Volumes[].VolumeId" --output text)
    if [ -z "$volume_id" ]; then
        return
    fi

    aws ec2 create-snapshot --volume-id "$volume_id" \
        --description "$(date -Iseconds)" \
        --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$name}]"
}

for i in "${VOLUMES[@]}"; do
    create_snapshot "$i"
done
