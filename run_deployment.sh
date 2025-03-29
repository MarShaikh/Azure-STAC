#!/bin/bash

# This script runs the STAC API database and application setup scripts sequentially.
#
# Prerequisites:
# 1. The files 'setup_db.sh' and 'setup_app.sh' MUST exist in the same directory.
# 2. These files MUST be configured with your specific Azure details (resource group,
#    ACR name, DB credentials, etc.). Placeholders like '<your-...>' must be replaced.
# 3. Both 'setup_db.sh' and 'setup_app.sh' MUST be executable (`chmod +x`).

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Prevent errors in a pipeline from being masked.
set -o pipefail

SCRIPT_DB="setup_db.sh"
SCRIPT_APP="setup_app.sh"

echo "--- Starting Full STAC API Deployment ---"

# --- Run Database Setup ---
echo ""
echo "==> Checking for $SCRIPT_DB..."
if [ ! -f "$SCRIPT_DB" ]; then
    echo "Error: Database setup script '$SCRIPT_DB' not found in the current directory." >&2
    exit 1
fi
if [ ! -x "$SCRIPT_DB" ]; then
    echo "Error: Database setup script '$SCRIPT_DB' is not executable. Run 'chmod +x $SCRIPT_DB'." >&2
    exit 1
fi

echo "==> Executing Database Setup ($SCRIPT_DB)..."
./"$SCRIPT_DB"
echo "==> Database Setup ($SCRIPT_DB) Finished."


# --- Run Application Setup ---
echo ""
echo "==> Checking for $SCRIPT_APP..."
if [ ! -f "$SCRIPT_APP" ]; then
    echo "Error: Application setup script '$SCRIPT_APP' not found in the current directory." >&2
    exit 1
fi
if [ ! -x "$SCRIPT_APP" ]; then
    echo "Error: Application setup script '$SCRIPT_APP' is not executable. Run 'chmod +x $SCRIPT_APP'." >&2
    exit 1
fi

echo "==> Executing Application Setup ($SCRIPT_APP)..."
./"$SCRIPT_APP"
echo "==> Application Setup ($SCRIPT_APP) Finished."


echo ""
echo "--- Full STAC API Deployment Script Finished ---"
echo "Please check the output of both scripts for any errors and verify your deployment in Azure."