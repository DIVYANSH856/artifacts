#!/bin/bash
# Creates VPC peering connections from the JIT bastion hub VPC to EKS VPCs.
#   - Reads peering config from a JSON file
#   - Creates peering requests (cross-account or same-account)
#   - Updates route tables on the requester side
#   - Updates security groups to allow HTTPS (443) from EKS VPC CIDR
#
# For same-account peerings, auto-accepts and configures both sides.
# For cross-account peerings, run eks-account/1.eks-accepter.sh on the other side.
#
# Usage: ./3.setup-vpc-peering.sh <config-file.json>
#
# Run this in the JIT WORKLOAD ACCOUNT.
###############################################################################
set -euo pipefail

###############################################################################
# Helper functions
###############################################################################
handle_error() {
    local exit_code=$?
    echo "[ERROR] Line $1, exit code $exit_code" >&2
    exit $exit_code
}
trap 'handle_error $LINENO' ERR

log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

REQUESTER_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
REQUESTER_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

# Prompt to confirm/override region
read -rp "AWS Region for requester VPC [$REQUESTER_REGION]: " INPUT_REGION
REQUESTER_REGION="${INPUT_REGION:-$REQUESTER_REGION}"
export AWS_DEFAULT_REGION="$REQUESTER_REGION"

echo "Using region: $REQUESTER_REGION"
echo "Account: $REQUESTER_ACCOUNT_ID"

wait_for_peering_status() {
    local peering_id=$1
    local target_status=$2
    local max_attempts=30
    local wait_time=10
    local attempt=1
    log "Waiting for peering $peering_id to reach '$target_status'..."
    while [ $attempt -le $max_attempts ]; do
        status=$(aws ec2 describe-vpc-peering-connections \
            --vpc-peering-connection-ids "$peering_id" \
            --query 'VpcPeeringConnections[0].Status.Code' --output text)
        log "  Status: $status (attempt $attempt/$max_attempts)"
        if [ "$status" = "$target_status" ]; then
            return 0
        elif [ "$status" = "active" ]; then
            return 0
        elif [ "$status" = "failed" ] || [ "$status" = "rejected" ] || [ "$status" = "deleted" ]; then
            log "Peering reached terminal state: $status"
            return 1
        fi
        sleep $wait_time
        attempt=$((attempt + 1))
    done
    log "Timeout waiting for status '$target_status'. Current: $status"
    return 1
}

get_route_table_ids() {
    local vpc_id=$1
    aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'RouteTables[*].RouteTableId' --output text
}

update_routes() {
    local vpc_id=$1
    local destination_cidr=$2
    local peering_id=$3
    log "Updating route tables for VPC $vpc_id → $destination_cidr via $peering_id"
    for rt_id in $(get_route_table_ids "$vpc_id"); do
        aws ec2 create-route --route-table-id "$rt_id" \
            --destination-cidr-block "$destination_cidr" \
            --vpc-peering-connection-id "$peering_id" > /dev/null 2>&1 || \
        aws ec2 replace-route --route-table-id "$rt_id" \
            --destination-cidr-block "$destination_cidr" \
            --vpc-peering-connection-id "$peering_id" > /dev/null 2>&1 || true
    done
}

update_routes_in_region() {
    local vpc_id=$1
    local destination_cidr=$2
    local peering_id=$3
    local region=$4
    log "Updating route tables for VPC $vpc_id → $destination_cidr via $peering_id (region: $region)"
    for rt_id in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'RouteTables[*].RouteTableId' --output text --region "$region" 2>/dev/null); do
        aws ec2 create-route --route-table-id "$rt_id" \
            --destination-cidr-block "$destination_cidr" \
            --vpc-peering-connection-id "$peering_id" \
            --region "$region" > /dev/null 2>&1 || \
        aws ec2 replace-route --route-table-id "$rt_id" \
            --destination-cidr-block "$destination_cidr" \
            --vpc-peering-connection-id "$peering_id" \
            --region "$region" > /dev/null 2>&1 || true
    done
}

update_security_group() {
    local sg_id=$1
    local cidr=$2
    log "Updating SG $sg_id: allow HTTPS (443) from $cidr"
    aws ec2 authorize-security-group-ingress --group-id "$sg_id" \
        --protocol tcp --port 443 --cidr "$cidr" > /dev/null 2>&1 || true
}

###############################################################################
# Main
###############################################################################
process_peering_config() {
    local config_file=$1
    local config=$(cat "$config_file")

    echo "$config" | jq -c '.vpc_peerings[]' | while read -r peering; do
        local requester_vpc_id=$(echo "$peering" | jq -r '.requester_vpc_id')
        local accepter_account_id=$(echo "$peering" | jq -r '.accepter_account_id')
        local accepter_vpc_id=$(echo "$peering" | jq -r '.accepter_vpc_id')
        local accepter_region=$(echo "$peering" | jq -r '.accepter_region')
        local peering_name=$(echo "$peering" | jq -r '.peering_name')
        local accepter_cidr=$(echo "$peering" | jq -r '.accepter_cidr')
        local bastion_security_group_id=$(echo "$peering" | jq -r '.bastion_security_group_id')

        # Check if peering already exists
        local existing_peering=$(aws ec2 describe-vpc-peering-connections \
            --filters "Name=requester-vpc-info.vpc-id,Values=$requester_vpc_id" \
                      "Name=accepter-vpc-info.vpc-id,Values=$accepter_vpc_id" \
                      "Name=status-code,Values=active,pending-acceptance,provisioning" \
            --query 'VpcPeeringConnections[0].VpcPeeringConnectionId' --output text 2>/dev/null)

        if [ -n "$existing_peering" ] && [ "$existing_peering" != "None" ]; then
            log "Peering already exists: $existing_peering"
            peering_id="$existing_peering"
        else
            # Create peering
            log "Creating peering: $requester_vpc_id → $accepter_vpc_id (account $accepter_account_id, region $accepter_region)..."

            local peer_region_flag=""
            if [ "$accepter_region" != "$REQUESTER_REGION" ]; then
                peer_region_flag="--peer-region $accepter_region"
            fi

            peering_id=$(aws ec2 create-vpc-peering-connection \
                --vpc-id "$requester_vpc_id" \
                --peer-owner-id "$accepter_account_id" \
                --peer-vpc-id "$accepter_vpc_id" \
                $peer_region_flag \
                --tag-specifications "ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=${peering_name}},{Key=Purpose,Value=eks-jit},{Key=created_by,Value=cloudanix}]" \
                --query 'VpcPeeringConnection.VpcPeeringConnectionId' --output text)

            if [ -z "$peering_id" ] || [ "$peering_id" = "None" ]; then
                log "ERROR: Failed to create peering connection"
                exit 1
            fi
            log "Created: $peering_id"
        fi

        # Same account → auto-accept
        if [ "$accepter_account_id" = "$REQUESTER_ACCOUNT_ID" ]; then
            log "Same account detected — auto-accepting peering..."
            wait_for_peering_status "$peering_id" "pending-acceptance"

            # Accept must be in the accepter's region
            aws ec2 accept-vpc-peering-connection \
                --vpc-peering-connection-id "$peering_id" \
                --region "$accepter_region" > /dev/null
            wait_for_peering_status "$peering_id" "active"
            log "Peering active: $peering_id"

            # Update routes on BOTH sides for same-account
            update_routes "$requester_vpc_id" "$accepter_cidr" "$peering_id"
            local requester_cidr=$(aws ec2 describe-vpcs --vpc-ids "$requester_vpc_id" --query 'Vpcs[0].CidrBlock' --output text)
            # Accepter-side routes need accepter region
            update_routes_in_region "$accepter_vpc_id" "$requester_cidr" "$peering_id" "$accepter_region"
            update_security_group "$bastion_security_group_id" "$accepter_cidr"
        else
            # Cross-account → wait for pending-acceptance
            wait_for_peering_status "$peering_id" "pending-acceptance"
            log "Peering pending acceptance: $peering_id"
            log "Run eks-account/1.eks-accepter.sh in the EKS account (region: $accepter_region) to accept."

            # Update requester-side routes
            update_routes "$requester_vpc_id" "$accepter_cidr" "$peering_id"
            update_security_group "$bastion_security_group_id" "$accepter_cidr"
        fi

        echo "Peering: $peering_id ($peering_name) — accepter: $accepter_account_id" >> peering-details.txt
        log "Done: $peering_name → $peering_id"
    done
}

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <config-file.json>"
    echo ""
    echo "Config file format (see 4.vpc-peering-create-request.json for example):"
    echo '  {'
    echo '    "vpc_peerings": [{'
    echo '      "peering_name": "jit-eks-peering-1",'
    echo '      "requester_vpc_id": "vpc-xxx (bastion hub VPC)",'
    echo '      "accepter_account_id": "123456789012 (EKS account)",'
    echo '      "accepter_vpc_id": "vpc-yyy (EKS VPC)",'
    echo '      "accepter_region": "us-east-1",'
    echo '      "accepter_cidr": "10.0.0.0/16 (EKS VPC CIDR)",'
    echo '      "bastion_security_group_id": "sg-xxx (bastion hub SG)"'
    echo '    }]'
    echo '  }'
    exit 1
fi

process_peering_config "$1"
