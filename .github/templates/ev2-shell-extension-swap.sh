#!/bin/bash
# EV2 Shell Extension — Swap staging slot to production
# This script is bundled as a tar and executed by EV2 in an ACI container.
# EV2 injects: SubscriptionId, AzureResourceGroupName, Location, plus custom parameters.
set -euo pipefail

# CRITICAL: Set subscription context — the managed identity may have access to multiple subscriptions.
az account set --subscription "$SubscriptionId"

APP_NAME="$1"
SLOT_NAME="${2:-staging}"

echo "Swapping $APP_NAME: $SLOT_NAME → production in $AzureResourceGroupName ($SubscriptionId)"

az webapp deployment slot swap \
    --resource-group "$AzureResourceGroupName" \
    --name "$APP_NAME" \
    --slot "$SLOT_NAME" \
    --target-slot "production"

echo "Swap complete: $APP_NAME is now serving from former $SLOT_NAME"
