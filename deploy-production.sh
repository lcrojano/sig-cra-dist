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
# ✅ Pre-checks
# ==============================================================================

print_status "🚀 Starting production deployment..."

if [ "$EUID" -eq 0 ]; then
    print_warning "Running as root. Consider using a non-root user with sudo."
fi

# Docker check
if ! command -v docker &>/dev/null; then
    print_error "Docker is not installed."
    exit 1
fi

if ! docker info &>/dev/null; then
    print_error "Docker is not running."
    exit 1
fi

# Docker Compose check
if command -v docker-compose &>/dev/null; then
    DOCKER_COMPOSE="docker-compose"
elif docker compose version &>/dev/null; then
    DOCKER_COMPOSE="docker compose"
else
    print_error "Docker Compose is not installed."
    exit 1
fi

COMPOSE_CMD="$DOCKER_COMPOSE -f docker-compose.yml -f docker-compose.cra.yml"

# Required Compose files
[ -f "docker-compose.yml" ] || { print_error "Missing docker-compose.yml"; exit 1; }
[ -f "docker-compose.cra.yml" ] || { print_error "Missing docker-compose.cra.yml"; exit 1; }

# Load root .env
if [ -f ".env" ]; then
    print_status "Loading environment variables from root .env"
    set -a; source .env; set +a
else
    print_warning "Root .env file not found. Make sure DB variables are set."
fi

# ==============================================================================
# 🛠️ Laravel Environment File Setup
# ==============================================================================

LARAVEL_ENV_PATH="apps/api-laravel"
EXAMPLE_FILE="$LARAVEL_ENV_PATH/.env.example"
ENV_FILE="$LARAVEL_ENV_PATH/.env"

if [ ! -f "$EXAMPLE_FILE" ]; then
    print_error "Missing Laravel .env.example at $EXAMPLE_FILE"
    exit 1
fi

print_status "Generating Laravel .env from .env.example..."
sed "s|sig-cra\.metamagagency\.com|$DOMAIN|g" "$EXAMPLE_FILE" > "$ENV_FILE"
print_status "✅ Laravel .env created at $ENV_FILE with domain: $DOMAIN"

# ==============================================================================
# 🌐 Angular App Config Setup
# ==============================================================================

CONFIG_PATH="apps/client-ui/dist/browser/assets"
CONFIG_EXAMPLE="$CONFIG_PATH/app.config.json.example"
CONFIG_FILE="$CONFIG_PATH/app.config.json"

print_status "Generating dynamic Angular app.config.json..."
sed "s|sig-cra\.metamagagency\.com|$DOMAIN|g" "$CONFIG_EXAMPLE" > "$CONFIG_FILE"
print_status "✅ app.config.json created with domain: $DOMAIN"

# ==============================================================================
# 🧩 Replace Mysql Migration Base URLs
# ==============================================================================

print_status "Replacing base URLs in Mysql migrations..."
./tools/scripts/replace_migration_urls.sh "https://api.$DOMAIN" "https://tiles.$DOMAIN"

# ==============================================================================
# 🔐 MySQL Secrets & Backup
# ==============================================================================

print_status "Creating MySQL root password secret file..."
echo -n "$DB_ROOT_PASSWORD" > tools/docker/mysql/secrets/mysql_root_password.txt

if $COMPOSE_CMD ps | grep -q "Up"; then
    print_status "Creating backup of current database..."
    $COMPOSE_CMD exec -T mysql mysqldump -u root -p${DB_ROOT_PASSWORD:-password} ${DB_DATABASE:-forge} > "backup_$(date +%Y%m%d_%H%M%S).sql" || \
    print_warning "Could not create database backup"
fi

# ==============================================================================
# 🧹 Docker Cleanup
# ==============================================================================

print_status "Stopping existing containers..."
$COMPOSE_CMD down --remove-orphans --filter "label=com.metamag.project=sig-platform" || true

print_status "Cleaning up unused Docker resources..."
docker system prune -f --filter "label=com.metamag.project=sig-platform" || true

print_status "Pulling latest Docker images..."
$COMPOSE_CMD pull || true

# ==============================================================================
# 🏗️ Build & Start Services
# ==============================================================================

print_status "Building and starting containers..."
$COMPOSE_CMD up -d --build

print_status "Waiting for containers to initialize..."
sleep 10
$COMPOSE_CMD ps

# ==============================================================================
# 🕒 Wait for MySQL and Services
# ==============================================================================

wait_for_database() {
    print_status "Waiting for MySQL to be ready..."
    local max_attempts=60 attempt=1
    while [ $attempt -le $max_attempts ]; do
        if $COMPOSE_CMD exec -T mysql mysqladmin ping -h localhost -u${DB_USERNAME:-forge} -p${DB_PASSWORD:-password} --silent >/dev/null 2>&1; then
            print_status "MySQL is ready ✅"
            return 0
        fi
        print_debug "Attempt $attempt/$max_attempts - MySQL not ready..."
        sleep 5
        ((attempt++))
    done
    print_error "MySQL did not start in time."
    return 1
}

check_service_health() {
    local service_name=$1
    local max_attempts=30 attempt=1
    print_status "Checking health of $service_name..."
    while [ $attempt -le $max_attempts ]; do
        if $COMPOSE_CMD ps $service_name | grep -q "Up"; then
            if $COMPOSE_CMD exec -T $service_name wget --quiet --tries=1 --spider http://localhost/ 2>/dev/null || \
               $COMPOSE_CMD exec -T $service_name curl -f http://localhost/ >/dev/null 2>&1; then
                print_status "$service_name is healthy ✅"
                return 0
            fi
        fi
        print_debug "Attempt $attempt/$max_attempts - $service_name not ready..."
        sleep 5
        ((attempt++))
    done
    print_warning "$service_name health check timed out."
    return 1
}

wait_for_database
sleep 20
check_service_health "client-ui-nginx" || print_warning "Client UI health check failed"
check_service_health "api-laravel-nginx" || print_warning "Laravel Nginx health check failed"
check_service_health "tileserver" || print_warning "Tileserver health check failed"

# ==============================================================================
# 🔐 Traefik SSL Verification
# ==============================================================================

print_status "Checking Traefik SSL certificate status..."
if $COMPOSE_CMD logs traefik | grep -E -q "certificatesResolvers|ACME|Let's Encrypt"; then
    print_status "Traefik SSL is configured ✅"
else
    print_warning "SSL certificates may not be configured. Check Traefik logs:"
    $COMPOSE_CMD logs --tail=10 traefik
fi

# ==============================================================================
# ⚙️ Laravel Optimization & Permissions
# ==============================================================================

print_status "Setting up Laravel..."

if ! grep -q "APP_KEY=base64:" "$ENV_FILE"; then
    print_status "Generating Laravel application key..."
    $COMPOSE_CMD exec -T api-laravel php artisan key:generate --force || \
    print_warning "Failed to generate Laravel key"
fi

sleep 10

print_status "Running Laravel cache optimizations..."
$COMPOSE_CMD exec -T api-laravel php artisan config:cache || print_warning "Config cache failed"
$COMPOSE_CMD exec -T api-laravel php artisan route:cache || print_warning "Route cache failed"
$COMPOSE_CMD exec -T api-laravel php artisan view:cache  || print_warning "View cache failed"

print_status "Setting correct permissions..."
$COMPOSE_CMD exec -T api-laravel chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache || \
print_warning "Could not set Laravel permissions"

# ==============================================================================
# ✅ Final Checks
# ==============================================================================

print_status "Final service status check..."
services=("traefik" "client-ui-nginx" "api-laravel-nginx" "mysql" "tileserver")
failed_services=()

for service in "${services[@]}"; do
    if ! $DOCKER_COMPOSE ps $service | grep -q "Up"; then
        failed_services+=($service)
    fi
done

if [ ${#failed_services[@]} -gt 0 ]; then
    print_warning "Some services failed: ${failed_services[*]}"
    echo "💡 Check logs with: $DOCKER_COMPOSE logs [service-name]"
fi

# Final output
echo ""
echo "========================================"
print_status "🎉 Deployment completed!"
echo "========================================"
echo ""
echo "🌍 App:       https://$DOMAIN"
echo "🔧 API:       https://api.$DOMAIN"
echo "🗺️  Tiles:     https://tiles.$DOMAIN"
echo "📊 Traefik:   https://traefik.$DOMAIN"
echo ""
echo "🔐 SSL may take a few minutes to activate."
echo ""

# Quick commands
echo "Useful commands:"
echo "📋 Logs:      $DOCKER_COMPOSE logs -f [service-name]"
echo "📊 Status:    $DOCKER_COMPOSE ps"
echo "🛑 Stop:      $DOCKER_COMPOSE down"
echo "🔄 Restart:   $DOCKER_COMPOSE restart [service-name]"
echo "🐚 Shell:     $DOCKER_COMPOSE exec [service-name] bash"
echo ""

# Final local endpoint test
if curl -s -o /dev/null -w "%{http_code}" http://localhost | grep -q "200\|301\|302"; then
    print_status "Local HTTP is responding ✅"
else
    print_warning "Local HTTP may not be responding"
fi

print_status "🚀 Script finished. Monitor logs and verify all services."
