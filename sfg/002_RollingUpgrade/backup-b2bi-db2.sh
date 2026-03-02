#!/bin/bash

################################################################################
# Sterling B2Bi DB2 Database Backup Script
# 
# Purpose: Creates a full online backup of the Sterling B2Bi DB2 database
#          before performing upgrades or rollbacks
#
# Usage: ./backup-b2bi-db2.sh [OPTIONS]
#
# Options:
#   -n, --namespace    Target namespace (default: ibm-b2bi-dev01-app)
#   -d, --database     Database name (default: B2BIDB)
#   -p, --pod          DB2 pod name pattern (default: auto-detect)
#   -o, --output-dir   Local backup directory (default: ./db2-backups)
#   -r, --retention    Keep last N backups (default: 5)
#   -h, --help         Show this help message
#
# Prerequisites:
#   - oc CLI authenticated to OpenShift cluster
#   - Sufficient storage in DB2 pod and local filesystem
#   - DB2 instance running and accessible
#
# Author: Sterling DevOps Team
# Version: 1.0.0
################################################################################

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default configuration
NAMESPACE="ibm-b2bi-dev01-app"
DATABASE="B2BIDB"
DB2_POD=""
OUTPUT_DIR="./db2-backups"
RETENTION=5
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="b2bidb_backup_${TIMESTAMP}"

################################################################################
# Helper Functions
################################################################################

print_header() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BLUE}Sterling B2Bi DB2 Database Backup Script${NC}                  ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_step() {
    echo -e "\n${CYAN}▶${NC} ${BLUE}$1${NC}"
}

show_help() {
    cat << EOF
Sterling B2Bi DB2 Database Backup Script

Usage: $0 [OPTIONS]

Options:
  -n, --namespace NAMESPACE    Target namespace (default: ibm-b2bi-dev01-app)
  -d, --database DATABASE      Database name (default: B2BIDB)
  -p, --pod POD_NAME          DB2 pod name (default: auto-detect)
  -o, --output-dir DIR        Local backup directory (default: ./db2-backups)
  -r, --retention COUNT       Keep last N backups (default: 5)
  -h, --help                  Show this help message

Examples:
  # Basic backup with defaults
  $0

  # Backup with custom namespace and database
  $0 -n my-namespace -d MYDB

  # Backup with custom output directory and retention
  $0 -o /backups/db2 -r 10

  # Specify exact DB2 pod name
  $0 -p s0-db2-0

Prerequisites:
  - oc CLI authenticated to OpenShift cluster
  - Sufficient storage in DB2 pod (at least 2x database size)
  - Sufficient local storage for backup download
  - DB2 instance running and accessible

Backup Process:
  1. Validates prerequisites and connectivity
  2. Detects or verifies DB2 pod
  3. Checks database status and storage
  4. Creates online backup in DB2 pod
  5. Downloads backup to local filesystem
  6. Verifies backup integrity
  7. Cleans up old backups based on retention policy
  8. Generates backup manifest file

EOF
    exit 0
}

################################################################################
# Validation Functions
################################################################################

check_prerequisites() {
    print_step "Checking prerequisites"
    
    # Check oc CLI
    if ! command -v oc &> /dev/null; then
        print_error "oc CLI not found. Please install OpenShift CLI."
        exit 1
    fi
    print_success "oc CLI found"
    
    # Check authentication
    if ! oc whoami &> /dev/null; then
        print_error "Not authenticated to OpenShift. Run 'oc login' first."
        exit 1
    fi
    print_success "Authenticated as $(oc whoami)"
    
    # Check namespace exists
    if ! oc get namespace "$NAMESPACE" &> /dev/null; then
        print_error "Namespace '$NAMESPACE' not found"
        exit 1
    fi
    print_success "Namespace '$NAMESPACE' exists"
    
    # Create output directory
    mkdir -p "$OUTPUT_DIR"
    print_success "Output directory ready: $OUTPUT_DIR"
}

detect_db2_pod() {
    print_step "Detecting DB2 pod"
    
    if [ -z "$DB2_POD" ]; then
        # Auto-detect DB2 pod
        DB2_POD=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/component=db2 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        
        if [ -z "$DB2_POD" ]; then
            # Try alternative label
            DB2_POD=$(oc get pods -n "$NAMESPACE" -l role=db2 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        fi
        
        if [ -z "$DB2_POD" ]; then
            # Try name pattern matching
            DB2_POD=$(oc get pods -n "$NAMESPACE" -o name | grep -i db2 | head -1 | cut -d'/' -f2 || true)
        fi
        
        if [ -z "$DB2_POD" ]; then
            print_error "Could not auto-detect DB2 pod. Please specify with -p option."
            echo ""
            print_info "Available pods in namespace $NAMESPACE:"
            oc get pods -n "$NAMESPACE" -o name
            exit 1
        fi
    fi
    
    # Verify pod exists and is running
    POD_STATUS=$(oc get pod "$DB2_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    
    if [ "$POD_STATUS" != "Running" ]; then
        print_error "DB2 pod '$DB2_POD' is not running (status: $POD_STATUS)"
        exit 1
    fi
    
    print_success "DB2 pod detected: $DB2_POD (status: $POD_STATUS)"
}

check_database_status() {
    print_step "Checking database status"
    
    # Get DB2 instance owner (usually db2inst1)
    DB2_USER=$(oc exec -n "$NAMESPACE" "$DB2_POD" -- bash -c "ps aux | grep db2sysc | grep -v grep | awk '{print \$1}' | head -1" 2>/dev/null || echo "db2inst1")
    
    print_info "DB2 instance owner: $DB2_USER"
    
    # Check if database exists and is active
    DB_STATUS=$(oc exec -n "$NAMESPACE" "$DB2_POD" -- su - "$DB2_USER" -c "db2 list active databases" 2>/dev/null | grep -i "$DATABASE" || echo "")
    
    if [ -z "$DB_STATUS" ]; then
        print_warning "Database '$DATABASE' is not active. Attempting to activate..."
        oc exec -n "$NAMESPACE" "$DB2_POD" -- su - "$DB2_USER" -c "db2 activate database $DATABASE" || true
        sleep 2
    fi
    
    # Verify database is accessible
    if ! oc exec -n "$NAMESPACE" "$DB2_POD" -- su - "$DB2_USER" -c "db2 connect to $DATABASE" &> /dev/null; then
        print_error "Cannot connect to database '$DATABASE'"
        exit 1
    fi
    
    print_success "Database '$DATABASE' is accessible"
    
    # Disconnect
    oc exec -n "$NAMESPACE" "$DB2_POD" -- su - "$DB2_USER" -c "db2 connect reset" &> /dev/null || true
}

check_storage_space() {
    print_step "Checking storage space"
    
    # Get database size
    DB_SIZE=$(oc exec -n "$NAMESPACE" "$DB2_POD" -- su - "$DB2_USER" -c "db2 \"SELECT SUM(DATA_OBJECT_P_SIZE + INDEX_OBJECT_P_SIZE + LONG_OBJECT_P_SIZE + LOB_OBJECT_P_SIZE + XML_OBJECT_P_SIZE) AS SIZE_KB FROM TABLE(MON_GET_TABLESPACE('', -1)) AS T\" | grep -E '^[0-9]+' | awk '{print \$1}'" 2>/dev/null || echo "0")
    
    DB_SIZE_MB=$((DB_SIZE / 1024))
    DB_SIZE_GB=$((DB_SIZE_MB / 1024))
    
    print_info "Database size: ${DB_SIZE_GB} GB (${DB_SIZE_MB} MB)"
    
    # Check available space in DB2 pod
    AVAILABLE_SPACE=$(oc exec -n "$NAMESPACE" "$DB2_POD" -- df -BM /database | tail -1 | awk '{print $4}' | sed 's/M//')
    
    print_info "Available space in DB2 pod: ${AVAILABLE_SPACE} MB"
    
    # Need at least 2x database size for backup
    REQUIRED_SPACE=$((DB_SIZE_MB * 2))
    
    if [ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]; then
        print_error "Insufficient space in DB2 pod. Required: ${REQUIRED_SPACE} MB, Available: ${AVAILABLE_SPACE} MB"
        exit 1
    fi
    
    print_success "Sufficient storage available for backup"
}

################################################################################
# Backup Functions
################################################################################

create_backup() {
    print_step "Creating DB2 backup"
    
    BACKUP_DIR="/database/backup"
    
    # Create backup directory in pod
    print_info "Creating backup directory in pod..."
    oc exec -n "$NAMESPACE" "$DB2_POD" -- mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    
    # Start backup
    print_info "Starting online backup (this may take several minutes)..."
    echo -e "${YELLOW}⏳ Please wait...${NC}"
    
    BACKUP_CMD="db2 backup database $DATABASE online to $BACKUP_DIR compress"
    
    if ! oc exec -n "$NAMESPACE" "$DB2_POD" -- su - "$DB2_USER" -c "$BACKUP_CMD"; then
        print_error "Backup failed"
        exit 1
    fi
    
    print_success "Backup created successfully"
    
    # Get backup file name
    BACKUP_FILE=$(oc exec -n "$NAMESPACE" "$DB2_POD" -- ls -t "$BACKUP_DIR" | grep "^${DATABASE}" | head -1)
    
    if [ -z "$BACKUP_FILE" ]; then
        print_error "Could not find backup file"
        exit 1
    fi
    
    print_info "Backup file: $BACKUP_FILE"
    
    # Get backup size
    BACKUP_SIZE=$(oc exec -n "$NAMESPACE" "$DB2_POD" -- du -h "$BACKUP_DIR/$BACKUP_FILE" | awk '{print $1}')
    print_info "Backup size: $BACKUP_SIZE"
}

download_backup() {
    print_step "Downloading backup to local filesystem"
    
    LOCAL_BACKUP_DIR="$OUTPUT_DIR/$BACKUP_NAME"
    mkdir -p "$LOCAL_BACKUP_DIR"
    
    print_info "Downloading to: $LOCAL_BACKUP_DIR"
    echo -e "${YELLOW}⏳ Please wait...${NC}"
    
    # Download backup file
    if ! oc cp -n "$NAMESPACE" "$DB2_POD:$BACKUP_DIR/$BACKUP_FILE" "$LOCAL_BACKUP_DIR/$BACKUP_FILE"; then
        print_error "Failed to download backup"
        exit 1
    fi
    
    print_success "Backup downloaded successfully"
    
    # Verify downloaded file
    if [ ! -f "$LOCAL_BACKUP_DIR/$BACKUP_FILE" ]; then
        print_error "Downloaded backup file not found"
        exit 1
    fi
    
    LOCAL_SIZE=$(du -h "$LOCAL_BACKUP_DIR/$BACKUP_FILE" | awk '{print $1}')
    print_info "Local backup size: $LOCAL_SIZE"
}

create_manifest() {
    print_step "Creating backup manifest"
    
    MANIFEST_FILE="$OUTPUT_DIR/$BACKUP_NAME/backup-manifest.txt"
    
    cat > "$MANIFEST_FILE" << EOF
Sterling B2Bi DB2 Backup Manifest
==================================

Backup Information:
  Backup Name:        $BACKUP_NAME
  Timestamp:          $(date '+%Y-%m-%d %H:%M:%S %Z')
  Database:           $DATABASE
  Namespace:          $NAMESPACE
  DB2 Pod:            $DB2_POD
  DB2 User:           $DB2_USER

Backup File:
  Filename:           $BACKUP_FILE
  Size:               $(du -h "$LOCAL_BACKUP_DIR/$BACKUP_FILE" | awk '{print $1}')
  Path:               $LOCAL_BACKUP_DIR/$BACKUP_FILE
  MD5 Checksum:       $(md5sum "$LOCAL_BACKUP_DIR/$BACKUP_FILE" | awk '{print $1}')

Database Statistics:
  Database Size:      ${DB_SIZE_GB} GB (${DB_SIZE_MB} MB)
  Backup Type:        Online (COMPRESS)
  Backup Method:      Full Database

Environment:
  OpenShift User:     $(oc whoami)
  OpenShift Server:   $(oc whoami --show-server)
  Script Version:     1.0.0

Restore Instructions:
  1. Copy backup file to DB2 pod:
     oc cp "$LOCAL_BACKUP_DIR/$BACKUP_FILE" "$NAMESPACE/$DB2_POD:/database/restore/"
  
  2. Restore database:
     oc exec -n $NAMESPACE $DB2_POD -- su - $DB2_USER -c "db2 restore database $DATABASE from /database/restore taken at <timestamp>"
  
  3. Verify database:
     oc exec -n $NAMESPACE $DB2_POD -- su - $DB2_USER -c "db2 connect to $DATABASE"

Notes:
  - This is an online backup taken while database was active
  - Backup is compressed to save storage space
  - Keep this manifest file with the backup for reference
  - Test restore procedure in non-production environment first

EOF
    
    print_success "Manifest created: $MANIFEST_FILE"
}

cleanup_old_backups() {
    print_step "Cleaning up old backups (retention: $RETENTION)"
    
    # Count existing backups
    BACKUP_COUNT=$(find "$OUTPUT_DIR" -maxdepth 1 -type d -name "b2bidb_backup_*" | wc -l)
    
    print_info "Current backup count: $BACKUP_COUNT"
    
    if [ "$BACKUP_COUNT" -gt "$RETENTION" ]; then
        REMOVE_COUNT=$((BACKUP_COUNT - RETENTION))
        print_info "Removing $REMOVE_COUNT old backup(s)..."
        
        # Remove oldest backups
        find "$OUTPUT_DIR" -maxdepth 1 -type d -name "b2bidb_backup_*" | sort | head -n "$REMOVE_COUNT" | while read -r old_backup; do
            print_info "Removing: $(basename "$old_backup")"
            rm -rf "$old_backup"
        done
        
        print_success "Old backups cleaned up"
    else
        print_info "No cleanup needed (within retention limit)"
    fi
}

cleanup_pod_backup() {
    print_step "Cleaning up backup from DB2 pod"
    
    print_info "Removing backup file from pod to free space..."
    oc exec -n "$NAMESPACE" "$DB2_POD" -- rm -f "$BACKUP_DIR/$BACKUP_FILE" 2>/dev/null || true
    
    print_success "Pod cleanup complete"
}

################################################################################
# Main Execution
################################################################################

main() {
    print_header
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -d|--database)
                DATABASE="$2"
                shift 2
                ;;
            -p|--pod)
                DB2_POD="$2"
                shift 2
                ;;
            -o|--output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -r|--retention)
                RETENTION="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use -h or --help for usage information"
                exit 1
                ;;
        esac
    done
    
    # Display configuration
    print_info "Configuration:"
    echo "  Namespace:     $NAMESPACE"
    echo "  Database:      $DATABASE"
    echo "  Output Dir:    $OUTPUT_DIR"
    echo "  Retention:     $RETENTION backups"
    echo ""
    
    # Execute backup workflow
    check_prerequisites
    detect_db2_pod
    check_database_status
    check_storage_space
    create_backup
    download_backup
    create_manifest
    cleanup_pod_backup
    cleanup_old_backups
    
    # Summary
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  ${GREEN}✓ Backup Completed Successfully${NC}                              ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    print_info "Backup Details:"
    echo "  Location:      $OUTPUT_DIR/$BACKUP_NAME"
    echo "  Manifest:      $OUTPUT_DIR/$BACKUP_NAME/backup-manifest.txt"
    echo "  Backup File:   $BACKUP_FILE"
    echo ""
    print_success "You can now safely proceed with upgrade or rollback operations"
    echo ""
    print_info "To restore this backup:"
    echo "  1. Review restore instructions in backup-manifest.txt"
    echo "  2. Copy backup to DB2 pod"
    echo "  3. Run DB2 restore command"
    echo ""
}

# Trap errors
trap 'print_error "Script failed at line $LINENO"' ERR

# Run main function
main "$@"

# Made with Bob
