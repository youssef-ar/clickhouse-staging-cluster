#!/bin/bash
set -e

echo "Creating data backup..."

# Stop services to ensure consistent backup (volumes are not deleted)
docker compose stop

# Create backup directory
mkdir -p backup/volumes

# Backup all volumes
echo "Backing up volumes..."
for volume in clickhouse-staging-cluster_ch01_data clickhouse-staging-cluster_ch02_data clickhouse-staging-cluster_keeper01_data clickhouse-staging-cluster_keeper02_data clickhouse-staging-cluster_keeper03_data; do
    if docker volume inspect $volume >/dev/null 2>&1; then
        echo "Backing up $volume..."
        docker run --rm -v $volume:/data -v $(pwd)/backup/volumes:/backup alpine \
            tar czf /backup/${volume}.tar.gz -C /data .
    else
        echo "Volume $volume does not exist, skipping..."
    fi
done

# Move .tar.gz files to root
mv backup/volumes/*.tar.gz .

# Clean up temporary backup directory
rm -rf backup

# Restart services
docker compose start

echo "Backups created: *.tar.gz files"
