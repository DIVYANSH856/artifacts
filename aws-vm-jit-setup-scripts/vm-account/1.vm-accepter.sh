#!/bin/bash
set -e
set -u


handle_error() {
    local exit_code=$?
    echo "An error occurred on line $1, exit code $exit_code" >&2
    exit $exit_code
}
trap 'handle_error $LINENO' ERR

log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

get_route_table_ids() {
    local vpc_id=$1
    aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'RouteTables[].RouteTableId' --output text 2>/dev/null
}

wait_for_peering_active() {
    local peering_id=$1
    local max_attempts=20
    local wait_time=30
    local attempt=1
    log "Waiting for peering $peering_id to become active..."
    while [ $attempt -le $max_attempts ]; do
        status=$(aws ec2 describe-vpc-peering-connections \
            --vpc-peering-connection-ids "$peering_id" \
            --query 'VpcPeeringConnections[0].Status.Code' --output text 2>/dev/null)
        if [ "$status" = "active" ]; then
            log "Peering active"
            return 0
        elif [ "$status" = "failed" ]; then
            log "Peering failed"
            return 1
        fi
        sleep $wait_time
        attempt=$((attempt + 1))
    done
    return 1
}

process_accepter_config() {
    local config_file=$1
    local config=$(cat "$config_file")

    echo "$config" | jq -c '.vpc_peerings[]' | while read -r peering; do
        local requester_peering_id=$(echo "$peering" | jq -r '.requester_peering_id')
        local accepter_vpc_id=$(echo "$peering" | jq -r '.accepter_vpc_id')
        local requester_cidr=$(echo "$peering" | jq -r '.requester_cidr')
        local vm_security_groups=$(echo "$peering" | jq -r '.vm_security_groups[]')

        # Accept peering
        log "Accepting peering $requester_peering_id..."
        aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id "$requester_peering_id" > /dev/null 2>&1 || true

        wait_for_peering_active "$requester_peering_id"

        # Update route tables
        log "Updating route tables for VPC $accepter_vpc_id..."
        for rt_id in $(get_route_table_ids "$accepter_vpc_id"); do
            aws ec2 create-route --route-table-id "$rt_id" \
                --destination-cidr-block "$requester_cidr" \
                --vpc-peering-connection-id "$requester_peering_id" > /dev/null 2>&1 || true
        done

        # Update security groups — allow SSH from JIT VPC CIDR
        echo "$vm_security_groups" | while read -r sg_id; do
            if [ -n "$sg_id" ]; then
                log "Updating SG $sg_id: allow SSH from $requester_cidr"
                aws ec2 authorize-security-group-ingress --group-id "$sg_id" \
                    --protocol tcp --port 22 --cidr "$requester_cidr" > /dev/null 2>&1 || true
            fi
        done

        log "Done: peering $requester_peering_id accepted and configured"
    done
}

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <config-file.json>"
    exit 1
fi

process_accepter_config "$1"
