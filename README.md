# How to Use:

**Ensure Files Exist**: Make sure you have the previously generated (or manually created) setup_db.sh and setup_app.sh files in the same directory.

**Configure**: Crucially, edit setup_db.sh and setup_app.sh to replace all placeholder values (like <your-resource-group>, <your-acr-name>, <your_db_password>, etc.) with your actual Azure configuration details.

**Save**: Save the code above into a file named run_deployment.sh in that same directory.

**Make Executable**: Open your terminal in that directory and make all three scripts executable:
```bash
chmod +x setup_db.sh
chmod +x setup_app.sh
chmod +x run_deployment.sh
```

**Run**: Execute the main script:
```bash
./run_deployment.sh
```
 This script will first run `./setup_db.sh`. If it completes successfully, it will then run `./setup_app.sh`. If either script encounters an error (and exits because of `set -e`), the `run_deployment.sh` script will stop.
