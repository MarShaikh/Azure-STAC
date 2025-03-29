#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Prevent errors in a pipeline from being masked.
set -o pipefail

echo "--- Starting STAC API Azure Container App Deployment ---"

# --- Configuration ---
# !!! IMPORTANT: EDIT THESE VALUES BEFORE RUNNING !!!
ACR_NAME=""        # Replace with your ACR name
RESOURCE_GROUP=""      # Replace with your Resource Group name
LOCATION=""                  # Or your preferred Azure region (e.g., "eastus", "westeurope")
CONTAINER_APP_ENV_NAME="" # Name for the Container App Environment
STAC_API_NAME=""            # Name for your Container App
MANAGED_IDENTITY_NAME="" # Name for the Managed Identity
IMAGE_NAME=""    # Name for the Docker image in ACR
IMAGE_TAG="latest"                  # Tag for the Docker image
GIT_REPO_URL="https://github.com/stac-utils/stac-fastapi-pgstac.git"
REPO_DIR="stac-fastapi-pgstac" # Local directory for the cloned repo

# --- Database Credentials (Replace with your actual values) ---
# IMPORTANT: Treat passwords securely. Consider Azure Key Vault for production.
DB_USER="stacadmin"
DB_PASS="" # <<<--- REPLACE WITH YOUR ACTUAL PASSWORD
DB_NAME=""
DB_HOST="" # <<<--- REPLACE WITH YOUR DB HOST
DB_PORT=""
DB_SECRET_NAME="postgres-password-secret" # Name for the secret in Container Apps
DB_SSL_MODE="require" # Use 'require' or appropriate mode if your Azure DB enforces SSL ('prefer', 'disable', etc.)
# --- End Configuration ---

# --- Derived Variables ---
echo "Retrieving ACR login server..."
ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query loginServer --output tsv 2>/dev/null)
if [ -z "$ACR_LOGIN_SERVER" ]; then
    echo "Error: Could not retrieve ACR login server for ACR '$ACR_NAME' in resource group '$RESOURCE_GROUP'. Check names and permissions." >&2
    exit 1
fi
FULL_IMAGE_NAME="${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}"
echo "ACR Login Server: $ACR_LOGIN_SERVER"
echo "Full Image Name: $FULL_IMAGE_NAME"

# 2. Clone the Repository and Build the Docker Image in ACR
echo "--- Step 2: Clone Repository and Build Image in ACR ---"
if [ -d "$REPO_DIR" ]; then
    echo "Repository directory '$REPO_DIR' already exists. Skipping clone."
else
    echo "Cloning repository $GIT_REPO_URL into $REPO_DIR..."
    git clone "$GIT_REPO_URL" "$REPO_DIR"
fi
cd "$REPO_DIR" || { echo "Error: Failed to change directory to $REPO_DIR." >&2; exit 1; }

echo "Logging into ACR: $ACR_NAME..."
az acr login --name "$ACR_NAME"

echo "Building image $FULL_IMAGE_NAME in ACR $ACR_NAME from context '.'..."
az acr build \
  --registry "$ACR_NAME" \
  --image "${IMAGE_NAME}:${IMAGE_TAG}" \
  --resource-group "$RESOURCE_GROUP" \
  .

# Navigate back out of the repo directory
cd ..
echo "ACR build complete."

# 3. Create the Container App Environment
echo "--- Step 3: Create Container App Environment ---"
echo "Checking for existing Container App Environment: $CONTAINER_APP_ENV_NAME..."
ENV_EXISTS=$(az containerapp env show --name "$CONTAINER_APP_ENV_NAME" --resource-group "$RESOURCE_GROUP" --query name -o tsv 2>/dev/null || echo "")
if [ -n "$ENV_EXISTS" ]; then
    echo "Container App Environment '$CONTAINER_APP_ENV_NAME' already exists. Skipping creation."
else
    echo "Creating Container App Environment: $CONTAINER_APP_ENV_NAME..."
    az containerapp env create \
      --name "$CONTAINER_APP_ENV_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --location "$LOCATION"
    echo "Container App Environment created."
fi

# 4. Create a Managed Identity and Grant ACR Access
echo "--- Step 4: Create Managed Identity and Grant ACR Access ---"
echo "Checking for existing Managed Identity: $MANAGED_IDENTITY_NAME..."
IDENTITY_ID=$(az identity show --name "$MANAGED_IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv 2>/dev/null || echo "")

if [ -n "$IDENTITY_ID" ]; then
     echo "Managed Identity '$MANAGED_IDENTITY_NAME' already exists. Retrieving details..."
     IDENTITY_PRINCIPAL_ID=$(az identity show --name "$MANAGED_IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" --query principalId -o tsv)
else
    echo "Creating Managed Identity: $MANAGED_IDENTITY_NAME..."
    az identity create \
      --name "$MANAGED_IDENTITY_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --location "$LOCATION"
    echo "Retrieving Managed Identity details..."
    IDENTITY_ID=$(az identity show --name "$MANAGED_IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
    IDENTITY_PRINCIPAL_ID=$(az identity show --name "$MANAGED_IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" --query principalId -o tsv)
fi

if [ -z "$IDENTITY_ID" ] || [ -z "$IDENTITY_PRINCIPAL_ID" ]; then
    echo "Error: Could not retrieve Managed Identity details for '$MANAGED_IDENTITY_NAME'." >&2
    exit 1
fi
echo "Managed Identity ID: $IDENTITY_ID"
echo "Managed Identity Principal ID: $IDENTITY_PRINCIPAL_ID"

echo "Retrieving ACR Resource ID..."
ACR_ID=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
if [ -z "$ACR_ID" ]; then
    echo "Error: Could not retrieve ACR Resource ID for '$ACR_NAME'." >&2
    exit 1
fi
echo "ACR Resource ID: $ACR_ID"

echo "Checking for existing AcrPull role assignment..."
# Note: Checking existing role assignments precisely by principal ID via CLI can be complex.
# This command attempts the assignment; if it exists, Azure usually handles it gracefully (might show a message).
echo "Assigning AcrPull role to Managed Identity ($IDENTITY_PRINCIPAL_ID) on ACR ($ACR_ID)..."
az role assignment create \
  --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --scope "$ACR_ID" \
  --role AcrPull \
  --description "Grant $MANAGED_IDENTITY_NAME pull access to $ACR_NAME" || echo "Role assignment might already exist or failed."

echo "Managed Identity setup potentially complete."

# 5. Create the Container App
echo "--- Step 5: Create Container App ---"
echo "Checking for existing Container App: $STAC_API_NAME..."
APP_EXISTS=$(az containerapp show --name "$STAC_API_NAME" --resource-group "$RESOURCE_GROUP" --query name -o tsv 2>/dev/null || echo "")
if [ -n "$APP_EXISTS" ]; then
    echo "Container App '$STAC_API_NAME' already exists. Skipping creation."
    # Optionally, you might want to run an update command here if needed
else
    echo "Creating Container App: $STAC_API_NAME..."
    az containerapp create \
      --name "$STAC_API_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --environment "$CONTAINER_APP_ENV_NAME" \
      --image "$FULL_IMAGE_NAME" \
      --user-assigned "$IDENTITY_ID" \
      --registry-server "$ACR_LOGIN_SERVER" \
      --registry-identity "$IDENTITY_ID" \
      --target-port 8080 \
      --ingress external \
      --min-replicas 1 \
      --max-replicas 1 \
      --cpu 0.5 \
      --memory 1.0Gi
    echo "Container App $STAC_API_NAME created."
fi

# 6. Configure Secrets and Environment Variables
echo "--- Step 6: Configure Secrets and Environment Variables ---"
echo "Setting secret '$DB_SECRET_NAME' in Container App $STAC_API_NAME..."
az containerapp secret set \
  --name "$STAC_API_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --secrets "$DB_SECRET_NAME=$DB_PASS"

echo "Updating environment variables for Container App $STAC_API_NAME..."
az containerapp update \
  --name "$STAC_API_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --set-env-vars \
    "postgres_user=${DB_USER}" \
    "postgres_pass=secretref:${DB_SECRET_NAME}" \
    "postgres_dbname=${DB_NAME}" \
    "postgres_host_reader=${DB_HOST}" \
    "postgres_host_writer=${DB_HOST}" \
    "postgres_port=${DB_PORT}" \
    "app_host=0.0.0.0" \
    "app_port=8080" \
    "environment=production" \
    "web_concurrency=4" \
    "VSI_CACHE=TRUE" \
    "GDAL_HTTP_MERGE_CONSECUTIVE_RANGES=YES" \
    "GDAL_DISABLE_READDIR_ON_OPEN=EMPTY_DIR" \
    "DB_MIN_CONN_SIZE=1" \
    "DB_MAX_CONN_SIZE=5" \
    "USE_API_HYDRATE=false" \
    "PGSSLMODE=${DB_SSL_MODE}" # Added SSL Mode

echo "Secrets and environment variables configured."

# 7. Configure Health Probes (Using --yaml)
echo "--- Step 7: Configure Health Probes (Manual YAML Edit Required) ---"
CONFIG_YAML="app-config.yaml"
echo "Retrieving current app configuration for $STAC_API_NAME..."
az containerapp show \
  --name "$STAC_API_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --output yaml > "$CONFIG_YAML"
echo "Current configuration saved to $CONFIG_YAML"

echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "IMPORTANT: Manually edit the '$CONFIG_YAML' file now."
echo "Add or modify the 'probes:' section under 'template.containers[0]'."
echo "Ensure correct YAML indentation. Example block:"
echo ""
echo "          probes:"
echo "            - type: Startup"
echo "              httpGet:"
echo "                path: / # Or specific health endpoint e.g., /_health"
echo "                port: 8080"
echo "                scheme: Http"
echo "              initialDelaySeconds: 45"
echo "              periodSeconds: 15"
echo "              failureThreshold: 5"
echo "            - type: Readiness"
echo "              httpGet:"
echo "                path: / # Or specific health endpoint"
echo "                port: 8080"
echo "                scheme: Http"
echo "              initialDelaySeconds: 10"
echo "              periodSeconds: 10"
echo "              failureThreshold: 3"
echo "            - type: Liveness"
echo "              httpGet:"
echo "                path: / # Or specific health endpoint"
echo "                port: 8080"
echo "                scheme: Http"
echo "              initialDelaySeconds: 30"
echo "              periodSeconds: 20"
echo "              failureThreshold: 3"
echo ""
read -p "Press Enter when you have saved the changes to '$CONFIG_YAML'..."
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

echo "Applying updated configuration with probes from $CONFIG_YAML..."
az containerapp update \
  --name "$STAC_API_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --yaml "$CONFIG_YAML"
echo "Health probes configuration update applied."
# Consider removing the yaml file after use: rm "$CONFIG_YAML"

# 8. Verify Deployment
echo "--- Step 8: Verify Deployment ---"
# Note: Logs might take a moment to become available after app update/creation
echo "Attempting to retrieve application URL..."
APP_URL=$(az containerapp show --name "$STAC_API_NAME" --resource-group "$RESOURCE_GROUP" --query properties.configuration.ingress.fqdn -o tsv 2>/dev/null || echo "")

if [ -z "$APP_URL" ]; then
    echo "Warning: Could not retrieve application URL immediately. The app might still be starting/updating." >&2
    echo "You can check the status in the Azure portal or run:"
    echo "az containerapp show --name \"$STAC_API_NAME\" --resource-group \"$RESOURCE_GROUP\" --query properties.configuration.ingress.fqdn -o tsv"
else
    echo "-----------------------------------------------------"
    echo "Deployment potentially complete!"
    echo "Access your STAC API at: https://${APP_URL}"
    echo "Verify probes by checking logs and app responsiveness."
    echo "Example checks:"
    echo "curl \"https://${APP_URL}/\""
    echo "curl \"https://${APP_URL}/collections\""
    echo "-----------------------------------------------------"
fi

echo "You can tail logs using:"
echo "az containerapp logs show --name \"$STAC_API_NAME\" --resource-group \"$RESOURCE_GROUP\" --follow"
echo ""
echo "--- STAC API Azure Container App Deployment Script Finished ---"
