#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Prevent errors in a pipeline from being masked.
set -o pipefail

echo "--- Starting Azure PostgreSQL and pgSTAC Setup ---"

# --- Configuration ---
# !!! IMPORTANT: EDIT THESE VALUES BEFORE RUNNING !!!
DB_RESOURCE_GROUP=""           # Resource group for the database server
DB_SERVER_NAME=""               # Name for the new PostgreSQL Flexible Server
DB_LOCATION=""                      # Azure region for the database
DB_ADMIN_USER=""                  # Admin username for the database server
DB_ADMIN_PASS=""            # <<<--- REPLACE WITH A STRONG ADMIN PASSWORD
DB_SKU=""                     # VM SKU (e.g., Standard_B1ms, Standard_D2s_v3) - Check Azure docs for options
DB_TIER=""                        # Pricing tier (e.g., Burstable, GeneralPurpose, MemoryOptimized)
DB_STORAGE_SIZE=                         # Storage in GiB (e.g., 32)
DB_VERSION=""                            # PostgreSQL version (e.g., 13, 14, 15, 16)
DB_NAME_TO_CREATE="stac_db"                # Name of the specific database to create for STAC
DB_SSL_MODE="require"                      # SSL mode for connections ('require', 'prefer', 'disable')

# Firewall rule settings
ALLOW_AZURE_SERVICES_RULE="AllowAzureServices"
YOUR_IP_RULE_NAME="AllowMyDevIP"

# pgSTAC settings
PGSTAC_ROLE="pgstac_ingest"                 # Role name for pgstac migrations

# --- End Configuration ---

# --- Prerequisite Checks ---
if ! command -v az &> /dev/null; then
    echo "Error: Azure CLI (az) command not found. Please install and configure it." >&2
    exit 1
fi
if ! command -v psql &> /dev/null; then
    echo "Warning: psql command not found. Manual SQL execution will be required." >&2
fi
if ! command -v python &> /dev/null || ! command -v pip &> /dev/null ; then
    echo "Warning: python/pip command not found. Cannot install pypgstac automatically." >&2
fi
if ! command -v curl &> /dev/null; then
    echo "Warning: curl command not found. Cannot automatically detect your IP address." >&2
fi


# 1. Create PostgreSQL Flexible Server
echo "--- Step 1: Create PostgreSQL Flexible Server ---"
echo "Checking for existing server '$DB_SERVER_NAME'..."
SERVER_EXISTS=$(az postgres flexible-server show --name "$DB_SERVER_NAME" --resource-group "$DB_RESOURCE_GROUP" --query name -o tsv 2>/dev/null || echo "")

if [ -n "$SERVER_EXISTS" ]; then
    echo "PostgreSQL server '$DB_SERVER_NAME' already exists. Skipping creation."
    DB_HOST_FQDN=$(az postgres flexible-server show --name "$DB_SERVER_NAME" --resource-group "$DB_RESOURCE_GROUP" --query fullyQualifiedDomainName -o tsv)
else
    echo "Creating PostgreSQL server '$DB_SERVER_NAME'..."
    # Note: Creation can take several minutes.
    az postgres flexible-server create \
      --name "$DB_SERVER_NAME" \
      --resource-group "$DB_RESOURCE_GROUP" \
      --location "$DB_LOCATION" \
      --admin-user "$DB_ADMIN_USER" \
      --admin-password "$DB_ADMIN_PASS" \
      --sku-name "$DB_SKU" \
      --tier "$DB_TIER" \
      --storage-size "$DB_STORAGE_SIZE" \
      --version "$DB_VERSION"
    echo "Server creation initiated. Waiting a moment for FQDN..."
    sleep 30 # Give Azure a moment to populate details
    DB_HOST_FQDN=$(az postgres flexible-server show --name "$DB_SERVER_NAME" --resource-group "$DB_RESOURCE_GROUP" --query fullyQualifiedDomainName -o tsv)
    echo "Server '$DB_SERVER_NAME' created with FQDN: $DB_HOST_FQDN"
fi
if [ -z "$DB_HOST_FQDN" ]; then
    echo "Error: Could not retrieve FQDN for server '$DB_SERVER_NAME'." >&2
    exit 1
fi

# 2. Configure Firewall Rules
echo "--- Step 2: Configure Firewall Rules ---"
echo "Getting your public IP address..."
CURRENT_IP=$(curl -s icanhazip.com)
if [ -z "$CURRENT_IP" ]; then
    echo "Warning: Could not automatically detect your IP. Skipping firewall rule '$YOUR_IP_RULE_NAME'." >&2
    echo "You may need to add it manually in the Azure portal."
else
    echo "Allowing your current IP address ($CURRENT_IP) via rule '$YOUR_IP_RULE_NAME'..."
    az postgres flexible-server firewall-rule create \
      --resource-group "$DB_RESOURCE_GROUP" \
      --name "$DB_SERVER_NAME" \
      --rule-name "$YOUR_IP_RULE_NAME" \
      --start-ip-address "$CURRENT_IP" \
      --end-ip-address "$CURRENT_IP" || echo "Rule '$YOUR_IP_RULE_NAME' might already exist or failed."
fi

echo "Allowing Azure Services via rule '$ALLOW_AZURE_SERVICES_RULE'..."
az postgres flexible-server firewall-rule create \
  --resource-group "$DB_RESOURCE_GROUP" \
  --name "$DB_SERVER_NAME" \
  --rule-name "$ALLOW_AZURE_SERVICES_RULE" \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 0.0.0.0 || echo "Rule '$ALLOW_AZURE_SERVICES_RULE' might already exist or failed."
echo "Firewall rules configured."

# 3. & 4. Connect & Create Database (Instructions)
# Cannot reliably automate psql connection/commands without user interaction for password
# or potentially insecure password exposure in environment variables/command line.
echo "--- Step 3 & 4: Create Database ---"
echo "Please connect to the PostgreSQL server using psql or another tool and run the following SQL commands:"
echo ""
echo "--------------------------------------------------"
echo "psql \"host=$DB_HOST_FQDN port=5432 user=$DB_ADMIN_USER dbname=postgres sslmode=$DB_SSL_MODE\""
echo "-- (You will be prompted for the admin password: '$DB_ADMIN_PASS')"
echo ""
echo "-- Inside psql:"
echo "CREATE DATABASE $DB_NAME_TO_CREATE;"
echo "\\c $DB_NAME_TO_CREATE"
echo "--------------------------------------------------"
echo ""

# 5. Enable Required Extensions
echo "--- Step 5: Enable Required Extensions ---"
echo "Allowlisting extensions at the Azure server level..."
echo "Note: This may trigger a server restart which can take a few minutes."
az postgres flexible-server parameter set \
  --resource-group "$DB_RESOURCE_GROUP" \
  --server-name "$DB_SERVER_NAME" \
  --name azure.extensions \
  --value POSTGIS,POSTGIS_RASTER,BTREE_GIST,UNACCENT
echo "Extensions allowlisted."
echo "Please run the following SQL commands in the '$DB_NAME_TO_CREATE' database after connecting (Step 3/4):"
echo ""
echo "--------------------------------------------------"
echo "-- Connect first if not already connected:"
echo "-- \\c $DB_NAME_TO_CREATE"
echo ""
echo "-- Create extensions:"
echo "CREATE EXTENSION IF NOT EXISTS postgis;"
echo "CREATE EXTENSION IF NOT EXISTS postgis_raster;"
echo "CREATE EXTENSION IF NOT EXISTS btree_gist;"
echo "CREATE EXTENSION IF NOT EXISTS unaccent;"
echo "--------------------------------------------------"
echo ""

# 6. & 7. Set Up pgSTAC (Install pypgstac, Create Role, Run Migrations)
echo "--- Step 6 & 7: Set Up pgSTAC ---"
echo "Make sure you have Python and pip installed."
echo "Installing/updating pypgstac with psycopg..."
python -m pip install -U "pypgstac[psycopg]"

echo "Please ensure the required role '$PGSTAC_ROLE' is created and granted before running migrations."
echo "Run the following SQL commands in the '$DB_NAME_TO_CREATE' database:"
echo ""
echo "--------------------------------------------------"
echo "-- Connect first if not already connected:"
echo "-- \\c $DB_NAME_TO_CREATE"
echo ""
echo "-- Create and grant role for pgstac:"
echo "CREATE ROLE $PGSTAC_ROLE;"
echo "GRANT $PGSTAC_ROLE TO \"$DB_ADMIN_USER\";"
echo "--------------------------------------------------"
echo ""

echo "Setting environment variables for pypgstac migration..."
export PGHOST="$DB_HOST_FQDN"
export PGDATABASE="$DB_NAME_TO_CREATE"
export PGUSER="$DB_ADMIN_USER"
export PGPASSWORD="$DB_ADMIN_PASS" # CAUTION: Exposing password in environment
export PGPORT="5432"
export PGSSLMODE="$DB_SSL_MODE"

echo "Running pgSTAC migrations..."
# Note: This requires the DB, extensions, and role to be set up first.
# Wrap in a conditional block if psql is not available? No, pypgstac needs env vars anyway.
read -p "Verify the Database ($DB_NAME_TO_CREATE), Extensions, and Role ($PGSTAC_ROLE) are created, then press Enter to run migrations..."

pypgstac migrate

# Unset password variable for security
unset PGPASSWORD
echo "pgSTAC migration attempted."

# 8. Verify Setup (Instructions)
echo "--- Step 8: Verify Setup ---"
echo "You can verify the pgSTAC setup by connecting to the database and checking for pgstac tables:"
echo ""
echo "--------------------------------------------------"
echo "psql \"host=$DB_HOST_FQDN port=5432 user=$DB_ADMIN_USER dbname=$DB_NAME_TO_CREATE sslmode=$DB_SSL_MODE\""
echo "-- (Enter password: '$DB_ADMIN_PASS')"
echo ""
echo "-- Inside psql:"
echo "\\dt pgstac.*"
echo "--------------------------------------------------"
echo ""
echo "--- Azure PostgreSQL and pgSTAC Setup Script Finished ---"
