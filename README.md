# Simple STAC API Deployment on Azure

This repository provides scripts to deploy a STAC API on Azure.

## Overview

The goal of this project is to create a relatively **simpler, single-container deployment** of a STAC API suitable for running on Azure services like Azure Container Apps (ACA).

This deployment utilizes the **`stac-fastapi-pgstac`** backend, which connects a FastAPI-based STAC API implementation to a PostgreSQL database managed with PgSTAC.

> **STAC (SpatioTemporal Asset Catalog)** is a specification designed to standardize the way geospatial assets (like satellite imagery, drone captures, etc.) are described and cataloged online. This standardization makes it much easier to search, discover, and work with these assets across different providers and tools.

**Status:** Please note that this work is currently **in progress**. While functional, it may evolve. To the best of my knowledge, this setup represents one of the simplest, bare-bones methods for deploying a `stac-fastapi-pgstac` based STAC API on Azure.

## How to Use:

**1. Ensure Files Exist**: Make sure you have the previously generated (or manually created) `setup_db.sh` and `setup_app.sh` files in the same directory as `run_deployment.sh`.

**2. Configure**: Crucially, edit `setup_db.sh` and `setup_app.sh` to replace all placeholder values (like `<your-resource-group>`, `<your-acr-name>`, `<your_db_password>`, etc.) with your actual Azure configuration details.

**3. Save**: Save the deployment script code into a file named `run_deployment.sh` in that same directory.

**4. Make Executable**: Open your terminal in that directory and make all three scripts executable:
   ```bash
   chmod +x setup_db.sh
   chmod +x setup_app.sh
   chmod +x run_deployment.sh
   ```

**5. Run**: Execute the main script:
   ```bash
   ./run_deployment.sh
   ```
   This script will first run `./setup_db.sh`. If it completes successfully, it will then proceed to run `./setup_app.sh`. If either script encounters an error (and exits because of `set -e`), the `run_deployment.sh` script will stop execution immediately.