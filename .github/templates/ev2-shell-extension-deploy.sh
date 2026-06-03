#!/bin/bash
# EV2 Shell Extension — Deploy code to staging slot
# This script is bundled as a tar and executed by EV2 in an ACI container.
# EV2 injects: SubscriptionId, AzureResourceGroupName, Location, plus custom parameters.
set -euo pipefail

# CRITICAL: Set subscription context — the managed identity may have access to multiple subscriptions.
az account set --subscription "$SubscriptionId"

APP_NAME="$1"
ZIP_PATH="$2"
SLOT_NAME="${3:-staging}"

echo "Deploying $ZIP_PATH to $APP_NAME/$SLOT_NAME in $AzureResourceGroupName ($SubscriptionId)"

az webapp deployment source config-zip \
    --resource-group "$AzureResourceGroupName" \
    --name "$APP_NAME" \
    --slot "$SLOT_NAME" \
    --src "$ZIP_PATH" \
    --timeout 300

echo "Deploy complete: $APP_NAME/$SLOT_NAME"
