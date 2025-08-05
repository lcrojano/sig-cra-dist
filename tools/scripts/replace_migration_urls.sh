#!/bin/bash

# Input and output paths
INPUT_FILE="./tools/docker/mysql/backups/migration.base.sql"
OUTPUT_FILE="./tools/docker/mysql/migration/migration.sql"

# New values passed as arguments
API_URL="$1"
TILE_SERVER_URL="$2"

# Fail on unset variables or command errors
set -eu

# Validate input
if [ -z "$API_URL" ] || [ -z "$TILE_SERVER_URL" ]; then
  echo "Usage: $0 <API_URL> <TILE_SERVER_URL>"
  echo "Example: $0 https://api.example.com https://tiles.example.com"
  exit 1
fi

# Perform replacements and save to output file
sed \
  -e "s|http://localhost:8000|$API_URL|g" \
  -e "s|http://localhost:8082|$TILE_SERVER_URL|g" \
  "$INPUT_FILE" > "$OUTPUT_FILE"

echo "✅ Migration file created at $OUTPUT_FILE"