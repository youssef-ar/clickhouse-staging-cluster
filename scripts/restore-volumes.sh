#!/bin/bash
set -e

echo "Restoring volumes from .tar.gz files..."

# Check if at least one backup file exists
any_found=false
for volume in clickhouse-staging-cluster_ch01_data clickhouse-staging-cluster_ch02_data clickhouse-staging-cluster_keeper01_data clickhouse-staging-cluster_keeper02_data clickhouse-staging-cluster_keeper03_data; do
    if [ -f "${volume}.tar.gz" ]; then
        echo "Found backup for $volume..."
        any_found=true
    else
        echo "Warning: ${volume}.tar.gz not found, skipping..."
    fi
done

if [ "$any_found" = false ]; then
    echo "Error: No backup files found!"
    exit 1
fi

# Stop services to ensure consistent restore (volumes are not deleted)
docker compose stop

# Create volumes if they don't exist
echo "Checking and creating Docker volumes if needed..."
for volume in clickhouse-staging-cluster_ch01_data clickhouse-staging-cluster_ch02_data clickhouse-staging-cluster_keeper01_data clickhouse-staging-cluster_keeper02_data clickhouse-staging-cluster_keeper03_data; do
    if ! docker volume inspect $volume >/dev/null 2>&1; then
        echo "Creating volume $volume..."
        docker volume create $volume
    else
        echo "Volume $volume already exists, will overwrite data..."
    fi
done

# Restore each volume
echo "Restoring volumes..."
for volume in clickhouse-staging-cluster_ch01_data clickhouse-staging-cluster_ch02_data clickhouse-staging-cluster_keeper01_data clickhouse-staging-cluster_keeper02_data clickhouse-staging-cluster_keeper03_data; do
    if [ -f "${volume}.tar.gz" ]; then
        echo "Restoring $volume..."
        docker run --rm --user 101:101 -v $volume:/data -v $(pwd):/backup alpine \
            tar xzf /backup/${volume}.tar.gz -C /data
    else
        echo "Backup for $volume not found, skipping..."
    fi
done

echo "Volumes restored successfully!"
echo "Run 'docker compose up -d' to start the cluster."