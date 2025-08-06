#!/bin/bash

# ==============================================================================
# 🚀 Production Deployment Script for SIG Platform
# Usage: ./deploy-production.sh
# ==============================================================================

set -e  # Exit immediately on error

# ==============================================================================
# 🎨 Color definitions for status messages
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_debug()   { echo -e "${BLUE}[DEBUG]${NC} $1"; }

# ==============================================================================
# ✅ Pre-checks and Environment Validation
# ==============================================================================

print_status "🚀 Starting production deployment..."

# Load and validate root .env FIRST
if [ -f ".env" ]; then
    print_status "Loading environment variables from root .env"
    set -a; source .env; set +a
    
    # Validate critical environment variables
    REQUIRED_VARS=("DOMAIN" "DB_DATABASE" "DB_USERNAME" "DB_PASSWORD" "DB_ROOT_PASSWORD")
    OPTIONAL_VARS=("MAIL_FROM_NAME" "MAIL_FROM_ADDRESS" "MAIL_MAILER" "SENDGRID_API_KEY" "DB_HOST" "DB_PORT")
    MISSING_VARS=()
    
    for var in "${REQUIRED_VARS[@]}"; do
        if [ -z "${!var}" ]; then
            MISSING_VARS+=("$var")
        fi
    done
    
    if [ ${#MISSING_VARS[@]} -gt 0 ]; then
        print_error "Missing required environment variables in .env file:"
        printf '%s\n' "${MISSING_VARS[@]}"
        echo ""
        echo "Please ensure your .env file contains:"
        echo "DOMAIN=your-domain.com"
        echo "DB_DATABASE=your_database"
        echo "DB_USERNAME=your_db_user" 
        echo "DB_PASSWORD=your_db_password"
        echo "DB_ROOT_PASSWORD=your_root_password"
        echo ""
        echo "Optional variables:"
        echo "MAIL_FROM_NAME=\"Your Organization Name\""
        echo "MAIL_FROM_ADDRESS=noreply@your-domain.com"
        echo "MAIL_MAILER=sendgrid"
        echo "SENDGRID_API_KEY=your_sendgrid_key"
        exit 1
    fi
    
    # Validate optional mail configuration
    if [ -n "$MAIL_MAILER" ] && [ "$MAIL_MAILER" = "sendgrid" ] && [ -z "$SENDGRID_API_KEY" ]; then
        print_warning "SendGrid mailer configured but SENDGRID_API_KEY is missing"
        print_warning "Email functionality may not work properly"
    fi
    
    print_status "✅ Environment variables validated"
else
    print_error "Root .env file not found!"
    echo ""
    echo "Please create a .env file with the following variables:"
    echo "DOMAIN=your-domain.com"
    echo "DB_DATABASE=your_database"
    echo "DB_USERNAME=your_db_user"
    echo "DB_PASSWORD=your_db_password" 
    echo "DB_ROOT_PASSWORD=your_root_password"
    exit 1
fi

# User permissions check
if [ "$EUID" -eq 0 ]; then
    print_warning "Running as root. Consider using a non-root user with sudo for better security."
fi

# Docker checks
if ! command -v docker &>/dev/null; then
    print_error "Docker is not installed. Please install Docker first."
    exit 1
fi

if ! docker info &>/dev/null; then
    print_error "Docker is not running. Please start Docker service."
    exit 1
fi

# Docker Compose version check
if command -v docker-compose &>/dev/null; then
    DOCKER_COMPOSE="docker-compose"
    COMPOSE_VERSION=$(docker-compose version --short 2>/dev/null || echo "unknown")
    print_debug "Using docker-compose v$COMPOSE_VERSION"
elif docker compose version &>/dev/null; then
    DOCKER_COMPOSE="docker compose"
    print_debug "Using docker compose (v2)"
else
    print_error "Docker Compose is not installed. Please install Docker Compose."
    exit 1
fi

COMPOSE_CMD="$DOCKER_COMPOSE -f docker-compose.yml -f docker-compose.cra.yml"

# Required files check
REQUIRED_FILES=("docker-compose.yml" "docker-compose.cra.yml")
for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        print_error "Missing required file: $file"
        exit 1
    fi
done

print_status "✅ All pre-checks passed"

# ==============================================================================
# 🛠️ Laravel Environment File Setup
# ==============================================================================

LARAVEL_ENV_PATH="apps/api-laravel"
EXAMPLE_FILE="$LARAVEL_ENV_PATH/.env.example"
ENV_FILE="$LARAVEL_ENV_PATH/.env"

if [ ! -f "$EXAMPLE_FILE" ]; then
    print_error "Missing Laravel .env.example at $EXAMPLE_FILE"
    print_error "Please ensure the Laravel application structure is correct."
    exit 1
fi

print_status "Generating Laravel .env from .env.example..."

# Create Laravel env directory if it doesn't exist
mkdir -p "$LARAVEL_ENV_PATH"

# Validate domain format
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]?\.[a-zA-Z]{2,}$ ]]; then
    print_error "Invalid domain format: $DOMAIN"
    print_error "Please provide a valid domain (e.g., example.com)"
    exit 1
fi

# Copy the example file first
cp "$EXAMPLE_FILE" "$ENV_FILE"

# Update domain-related variables
sed -i "s|sig-cra\.metamagagency\.com|$DOMAIN|g" "$ENV_FILE"

# Update database configuration
sed -i "s|^DB_HOST=.*|DB_HOST=${DB_HOST:-mysql}|g" "$ENV_FILE"
sed -i "s|^DB_PORT=.*|DB_PORT=${DB_PORT:-3306}|g" "$ENV_FILE"
sed -i "s|^DB_DATABASE=.*|DB_DATABASE=$DB_DATABASE|g" "$ENV_FILE"
sed -i "s|^DB_USERNAME=.*|DB_USERNAME=$DB_USERNAME|g" "$ENV_FILE"
sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=$DB_PASSWORD|g" "$ENV_FILE"

# Update mail configuration if provided in root .env
if [ -n "$MAIL_FROM_NAME" ]; then
    sed -i "s|^MAIL_FROM_NAME=.*|MAIL_FROM_NAME=\"$MAIL_FROM_NAME\"|g" "$ENV_FILE"
fi

if [ -n "$MAIL_FROM_ADDRESS" ]; then
    sed -i "s|^MAIL_FROM_ADDRESS=.*|MAIL_FROM_ADDRESS=$MAIL_FROM_ADDRESS|g" "$ENV_FILE"
fi

if [ -n "$MAIL_MAILER" ]; then
    sed -i "s|^MAIL_MAILER=.*|MAIL_MAILER=$MAIL_MAILER|g" "$ENV_FILE"
fi

if [ -n "$SENDGRID_API_KEY" ]; then
    # Add SENDGRID_API_KEY if it doesn't exist, or update if it does
    if grep -q "^SENDGRID_API_KEY=" "$ENV_FILE"; then
        sed -i "s|^SENDGRID_API_KEY=.*|SENDGRID_API_KEY=$SENDGRID_API_KEY|g" "$ENV_FILE"
    else
        echo "SENDGRID_API_KEY=$SENDGRID_API_KEY" >> "$ENV_FILE"
    fi
fi

# Update APP_URL to match domain
sed -i "s|^APP_URL=.*|APP_URL=https://$DOMAIN|g" "$ENV_FILE"

# Set production environment
sed -i "s|^APP_ENV=.*|APP_ENV=production|g" "$ENV_FILE"
sed -i "s|^APP_DEBUG=.*|APP_DEBUG=false|g" "$ENV_FILE"

print_status "✅ Laravel .env created and configured with:"
print_status "   - Domain: $DOMAIN"
print_status "   - Database: $DB_DATABASE"
print_status "   - Database User: $DB_USERNAME"
if [ -n "$MAIL_FROM_ADDRESS" ]; then
    print_status "   - Mail From: $MAIL_FROM_ADDRESS"
fi
if [ -n "$MAIL_MAILER" ]; then
    print_status "   - Mail Provider: $MAIL_MAILER"
fi

# ==============================================================================
# 🌐 Angular App Config Setup
# ==============================================================================

CONFIG_PATH="apps/client-ui/src/assets"
CONFIG_EXAMPLE="$CONFIG_PATH/app.config.json.example"
CONFIG_FILE="$CONFIG_PATH/app.config.json"

# Check if Angular config exists
if [ ! -f "$CONFIG_EXAMPLE" ]; then
    print_warning "Angular config example not found at $CONFIG_EXAMPLE"
    print_warning "Skipping Angular config generation"
else
    print_status "Generating dynamic Angular app.config.json..."
    
    # Create config directory if it doesn't exist
    mkdir -p "$CONFIG_PATH"
    
    sed "s|sig-cra\.metamagagency\.com|$DOMAIN|g" "$CONFIG_EXAMPLE" > "$CONFIG_FILE"
    print_status "✅ app.config.json created with domain: $DOMAIN"
fi

# ==============================================================================
# 🔧 Nginx api Configuration Setup
# ==============================================================================

NGINX_CONFIG_PATH="tools/docker/nginx"
NGINX_EXAMPLE="$NGINX_CONFIG_PATH/api.custom.conf.example"
NGINX_CONFIG="$NGINX_CONFIG_PATH/api.custom.conf"

# Check if Nginx config example exists
if [ ! -f "$NGINX_EXAMPLE" ]; then
    print_warning "Nginx config example not found at $NGINX_EXAMPLE"
    print_warning "Skipping Nginx config generation"
else
    print_status "Generating Nginx configuration from example..."
    
    # Create nginx config directory if it doesn't exist
    mkdir -p "$NGINX_CONFIG_PATH"
    
    sed "s|sig-cra\.metamagagency\.com|$DOMAIN|g" "$NGINX_EXAMPLE" > "$NGINX_CONFIG"
    print_status "✅ api.custom.conf created with domain: $DOMAIN"
fi

# ==============================================================================
# 🔧 Nginx Client Configuration Setup
# ==============================================================================

NGINX_CONFIG_PATH="tools/docker/nginx"
NGINX_EXAMPLE="$NGINX_CONFIG_PATH/client.custom.conf.example"
NGINX_CONFIG="$NGINX_CONFIG_PATH/client.custom.conf"

# Check if Nginx config example exists
if [ ! -f "$NGINX_EXAMPLE" ]; then
    print_warning "Nginx client config example not found at $NGINX_EXAMPLE"
    print_warning "Skipping Nginx config generation"
else
    print_status "Generating client Nginx configuration from example..."
    
    # Create nginx config directory if it doesn't exist
    mkdir -p "$NGINX_CONFIG_PATH"
    
    sed "s|sig-cra\.metamagagency\.com|$DOMAIN|g" "$NGINX_EXAMPLE" > "$NGINX_CONFIG"
    print_status "✅ client.custom.conf created with domain: $DOMAIN"
fi


# ==============================================================================
# 🧩 Replace MySQL Migration Base URLs
# ==============================================================================

MIGRATION_SCRIPT="./tools/scripts/replace_migration_urls.sh"
if [ -f "$MIGRATION_SCRIPT" ]; then
    print_status "Replacing base URLs in MySQL migrations..."
    chmod +x "$MIGRATION_SCRIPT"
    "$MIGRATION_SCRIPT" "https://api.$DOMAIN" "https://tiles.$DOMAIN"
    print_status "✅ Migration URLs updated"
else
    print_warning "Migration URL replacement script not found at $MIGRATION_SCRIPT"
fi

# ==============================================================================
# 🔐 MySQL Secrets Setup
# ==============================================================================

SECRETS_DIR="tools/docker/mysql/secrets"
ROOT_PASSWORD_FILE="$SECRETS_DIR/mysql_root_password.txt"

print_status "Setting up MySQL secrets..."

# Create secrets directory if it doesn't exist
mkdir -p "$SECRETS_DIR"

# Create root password file
echo -n "$DB_ROOT_PASSWORD" > "$ROOT_PASSWORD_FILE"
chmod 600 "$ROOT_PASSWORD_FILE"  # Secure the password file
print_status "✅ MySQL root password secret created"

# ==============================================================================
# 💾 Database Backup (if containers are running)
# ==============================================================================

if $COMPOSE_CMD ps mysql 2>/dev/null | grep -q "Up"; then
    BACKUP_FILE="backup_$(date +%Y%m%d_%H%M%S).sql"
    print_status "Creating backup of current database..."
    
    if $COMPOSE_CMD exec -T mysql mysqladmin ping -h localhost -u root -p"${DB_ROOT_PASSWORD}" --silent >/dev/null 2>&1; then
        $COMPOSE_CMD exec -T mysql mysqldump -u root -p"${DB_ROOT_PASSWORD}" "${DB_DATABASE}" > "$BACKUP_FILE" 2>/dev/null || {
            print_warning "Could not create database backup"
            rm -f "$BACKUP_FILE"  # Remove empty backup file
        }
        
        if [ -f "$BACKUP_FILE" ] && [ -s "$BACKUP_FILE" ]; then
            print_status "✅ Database backup created: $BACKUP_FILE"
        fi
    else
        print_warning "Database not accessible for backup"
    fi
fi

# ==============================================================================
# 🧹 Docker Cleanup and Preparation
# ==============================================================================

print_status "Stopping existing containers..."
$COMPOSE_CMD down --remove-orphans 2>/dev/null || print_warning "Some containers were already stopped"

print_status "Cleaning up unused Docker resources..."
docker system prune -f --filter "label=com.metamag.project=sig-platform" 2>/dev/null || true

print_status "Pulling latest Docker images..."
$COMPOSE_CMD pull || print_warning "Some images could not be pulled (may be built locally)"

# ==============================================================================
# 🏗️ Build & Start Services
# ==============================================================================

print_status "Building and starting containers..."
$COMPOSE_CMD up -d --build

print_status "Waiting for initial container startup..."
sleep 15

print_status "Container status:"
$COMPOSE_CMD ps

# ==============================================================================
# 🕒 Service Health Checks
# ==============================================================================

wait_for_database() {
    print_status "Waiting for MySQL to be ready..."
    local max_attempts=60 attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if $COMPOSE_CMD exec -T mysql mysqladmin ping -h localhost -u root -p"${DB_ROOT_PASSWORD}" --silent >/dev/null 2>&1; then
            print_status "✅ MySQL is ready"
            return 0
        fi
        
        if [ $((attempt % 10)) -eq 0 ]; then
            print_debug "Attempt $attempt/$max_attempts - MySQL still starting..."
        fi
        
        sleep 5
        ((attempt++))
    done
    
    print_error "MySQL did not start within expected time"
    print_error "Check MySQL logs: $COMPOSE_CMD logs mysql"
    return 1
}

check_service_health() {
    local service_name=$1
    local health_endpoint=${2:-"/"}
    local max_attempts=30 
    local attempt=1
    
    print_status "Checking health of $service_name..."
    
    while [ $attempt -le $max_attempts ]; do
        # Check if container is running
        if ! $COMPOSE_CMD ps "$service_name" 2>/dev/null | grep -q "Up"; then
            print_debug "Attempt $attempt/$max_attempts - $service_name container not running..."
            sleep 5
            ((attempt++))
            continue
        fi
        
        # Try health check endpoint
        if $COMPOSE_CMD exec -T "$service_name" curl -f -s "http://localhost$health_endpoint" >/dev/null 2>&1 || \
           $COMPOSE_CMD exec -T "$service_name" wget --quiet --tries=1 --spider "http://localhost$health_endpoint" >/dev/null 2>&1; then
            print_status "✅ $service_name is healthy"
            return 0
        fi
        
        if [ $((attempt % 5)) -eq 0 ]; then
            print_debug "Attempt $attempt/$max_attempts - $service_name not responding..."
        fi
        
        sleep 5
        ((attempt++))
    done
    
    print_warning "$service_name health check timed out"
    print_warning "Check logs: $COMPOSE_CMD logs $service_name"
    return 1
}

# Wait for core services
wait_for_database || {
    print_error "Database startup failed. Check configuration and try again."
    exit 1
}

sleep 10  # Additional wait for dependent services

# Check other services (non-blocking)
check_service_health "tileserver" "/health" || true
check_service_health "api-laravel-nginx" "/" || true

# ==============================================================================
# ⚙️ Laravel Setup and Optimization
# ==============================================================================

print_status "Configuring Laravel application..."

# Wait a bit more for Laravel to fully initialize
sleep 10

# Generate app key if not present
if ! grep -q "APP_KEY=base64:" "$ENV_FILE" 2>/dev/null; then
    print_status "Generating Laravel application key..."
    $COMPOSE_CMD exec -T api-laravel php artisan key:generate --force || {
        print_warning "Failed to generate Laravel key"
    }
else
    print_debug "Laravel app key already exists"
fi

# Run Laravel optimizations
print_status "Running Laravel optimizations..."

LARAVEL_COMMANDS=(
    "config:cache"
    "route:cache" 
    "view:cache"
)

for cmd in "${LARAVEL_COMMANDS[@]}"; do
    if $COMPOSE_CMD exec -T api-laravel php artisan $cmd >/dev/null 2>&1; then
        print_debug "✅ Laravel $cmd completed"
    else
        print_warning "Laravel $cmd failed"
    fi
done

# Fix permissions
print_status "Setting Laravel permissions..."
$COMPOSE_CMD exec -T api-laravel chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache 2>/dev/null || {
    print_warning "Could not set some Laravel permissions"
}

# ==============================================================================
# 🔐 SSL and Traefik Status
# ==============================================================================

print_status "Checking Traefik and SSL configuration..."

sleep 5  # Give Traefik time to start

if $COMPOSE_CMD logs traefik 2>/dev/null | grep -E -i -q "certificate|acme|letsencrypt|tls"; then
    print_status "✅ Traefik SSL configuration detected"
else
    print_warning "SSL certificates may not be configured yet"
    print_warning "SSL certificate generation can take a few minutes"
fi

# ==============================================================================
# ✅ Final Status Report
# ==============================================================================

print_status "Performing final service status check..."

# Define all expected services
EXPECTED_SERVICES=("traefik" "mysql" "api-laravel" "api-laravel-nginx" "tileserver")

# Check if CRA compose includes client-ui
if grep -q "client-ui-nginx:" docker-compose.cra.yml 2>/dev/null; then
    EXPECTED_SERVICES+=("client-ui-nginx")
fi

FAILED_SERVICES=()
RUNNING_SERVICES=()

for service in "${EXPECTED_SERVICES[@]}"; do
    if $COMPOSE_CMD ps "$service" 2>/dev/null | grep -q "Up"; then
        RUNNING_SERVICES+=("$service")
    else
        FAILED_SERVICES+=("$service")
    fi
done

# Report results
echo ""
echo "========================================"
print_status "🎉 Deployment Summary"
echo "========================================"
echo ""

if [ ${#RUNNING_SERVICES[@]} -gt 0 ]; then
    print_status "✅ Running services: ${RUNNING_SERVICES[*]}"
fi

if [ ${#FAILED_SERVICES[@]} -gt 0 ]; then
    print_warning "⚠️  Failed services: ${FAILED_SERVICES[*]}"
    echo ""
    echo "🔍 Troubleshooting commands:"
    for service in "${FAILED_SERVICES[@]}"; do
        echo "   $COMPOSE_CMD logs $service"
    done
    echo ""
fi

# Service URLs
echo "🌐 Service URLs:"
echo "   App:       https://$DOMAIN"
echo "   API:       https://api.$DOMAIN" 
echo "   Tiles:     https://tiles.$DOMAIN"

if grep -q "traefik.*api@internal" docker-compose.cra.yml 2>/dev/null; then
    echo "   Traefik:   https://traefik.$DOMAIN"
fi

if $COMPOSE_CMD ps phpmyadmin 2>/dev/null | grep -q "Up"; then
    echo "   PhpMyAdmin: https://pma.$DOMAIN"
fi

echo ""
echo "🔐 SSL certificates will be automatically generated by Let's Encrypt"
echo "   (This may take a few minutes on first deployment)"
echo ""

# Useful commands reference
echo "📋 Useful commands:"
echo "   Status:    $COMPOSE_CMD ps"
echo "   Logs:      $COMPOSE_CMD logs -f [service-name]"
echo "   Stop:      $COMPOSE_CMD down"
echo "   Restart:   $COMPOSE_CMD restart [service-name]"
echo "   Shell:     $COMPOSE_CMD exec [service-name] bash"
echo ""

# Quick connectivity test
print_status "Testing local connectivity..."
if curl -s -I --connect-timeout 5 http://localhost 2>/dev/null | head -n1 | grep -q "HTTP"; then
    print_status "✅ Local HTTP endpoint responding"
else
    print_warning "⚠️  Local HTTP endpoint not responding yet"
    print_warning "   This is normal if SSL redirect is enforced"
fi

# Final status
if [ ${#FAILED_SERVICES[@]} -eq 0 ]; then
    print_status "🚀 Deployment completed successfully!"
    echo ""
    echo "Next steps:"
    echo "1. Wait 2-5 minutes for SSL certificates to be generated"
    echo "2. Test your application at https://$DOMAIN"
    echo "3. Monitor logs if you encounter any issues"
else
    print_warning "⚠️  Deployment completed with some issues"
    echo ""
    echo "Please check the failed services and their logs before proceeding."
fi

echo ""
print_status "🔍 Monitor the deployment with: $COMPOSE_CMD logs -f"