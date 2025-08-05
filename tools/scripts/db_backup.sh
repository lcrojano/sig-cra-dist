#!/bin/bash
# production-backup.sh

BACKUP_DIR="./tools/backups/mysql"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=30

# Create timestamped directory
mkdir -p $BACKUP_DIR/$DATE

# 1. Full mysqldump backup
docker-compose exec -T mysql mysqldump \
  -u root -p${DB_ROOT_PASSWORD} \
  --all-databases \
  --routines --triggers --events \
  --single-transaction \
  --flush-logs \
  --master-data=2 \
  | gzip > $BACKUP_DIR/$DATE/mysql-full-dump.sql.gz

# 2. Configuration backup
cp -r ./tools/docker/mysql/my.cnf $BACKUP_DIR/$DATE/
cp -r ./tools/docker/mysql/ $BACKUP_DIR/$DATE/

# 3. Binary log backup (if enabled)

#docker-compose exec mysql mysqlbinlog --read-from-remote-server \

#  --host=localhost --stop-never mysql-bin > $BACKUP_DIR/$DATE/binlog-backup.sql &

# 4. Create backup manifest
cat > $BACKUP_DIR/$DATE/backup-info.txt << EOF
Backup Date: $(date)
MySQL Version: $(docker-compose exec mysql mysql --version)
Container: $(docker-compose ps mysql)
Databases: $(docker-compose exec mysql mysql -u root -p${DB_ROOT_PASSWORD} -e "SHOW DATABASES;" | grep -v Database)
Size: $(du -sh $BACKUP_DIR/$DATE)
EOF

# 5. Verify backup integrity
gunzip -t $BACKUP_DIR/$DATE/mysql-full-dump.sql.gz
if [ $? -eq 0 ]; then
    echo "✅ Backup verification successful"
else
    echo "❌ Backup verification failed!"
    exit 1
fi

# 6. Upload to remote storage (S3/GCS/etc)
# aws s3 sync $BACKUP_DIR/$DATE s3://your-backup-bucket/mysql/$DATE/

# 7. Clean old backups
find $BACKUP_DIR -type d -mtime +$RETENTION_DAYS -exec rm -rf {} +

echo "🎉 Production backup completed: $BACKUP_DIR/$DATE"