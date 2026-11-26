#!/usr/bin/env bash
#
# mongo_backup_to_github.sh
# Dumps MongoDB, compresses it, and pushes it to a GitHub repo
# inside a NEW timestamped directory (backups/YYYY-MM-DD_HH-MM-SS).
#
# Requirements: mongodump (mongodb-database-tools), git, tar, split
#
# Usage:
#   1. Edit the CONFIG section below (or export the variables / use a .env file)
#   2. chmod +x mongo_backup_to_github.sh
#   3. ./mongo_backup_to_github.sh
#
# Cron example (daily at 2:00 AM):
#   0 2 * * * /opt/scripts/mongo_backup_to_github.sh >> /var/log/mongo_backup.log 2>&1

set -euo pipefail

# ----------------------------- CONFIG ---------------------------------
# Optional: load settings from a .env file next to the script
ENV_FILE="$(dirname "$(readlink -f "$0")")/.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

# MongoDB
# Put this in .env (recommended):
#   MONGODB_URI=mongodb+srv://USER:PASSWORD@cluster.mongodb.net/DB_NAME
# The database name in the URI path decides what gets backed up
# (no database in the URI = all databases).
MONGODB_URI="${MONGODB_URI:-}"
if [[ -z "$MONGODB_URI" ]]; then
  echo "ERROR: MONGODB_URI is not set (add it to .env)." >&2
  exit 1
fi

# GitHub
# Option A (HTTPS + Personal Access Token):  https://github.com/USER/REPO.git  + GITHUB_TOKEN
# Option B (SSH):                            git@github.com:USER/REPO.git      (no token needed)
GITHUB_REPO="${GITHUB_REPO:-https://github.com/YOUR_USER/YOUR_BACKUP_REPO.git}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GIT_BRANCH="${GIT_BRANCH:-main}"
GIT_USER_NAME="${GIT_USER_NAME:-mongo-backup-bot}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-mongo-backup@localhost}"

# Backup layout
BACKUP_ROOT_DIR="${BACKUP_ROOT_DIR:-backups}"         # folder inside the repo
MAX_FILE_MB="${MAX_FILE_MB:-90}"                      # GitHub rejects files > 100 MB
# ----------------------------------------------------------------------

TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
WORK_DIR="$(mktemp -d /tmp/mongo_backup.XXXXXX)"
DUMP_FILE="$WORK_DIR/mongo_${TIMESTAMP}.archive.gz"
REPO_DIR="$WORK_DIR/repo"

log() { echo "[$(date '+%F %T')] $*"; }

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# Prevent overlapping runs
exec 200>/tmp/mongo_backup.lock
flock -n 200 || { log "Another backup is already running. Exiting."; exit 1; }

# Check dependencies
for cmd in mongodump git split; do
  command -v "$cmd" >/dev/null 2>&1 || { log "ERROR: '$cmd' is not installed."; exit 1; }
done

# Build authenticated repo URL if a token is provided (HTTPS only)
REPO_URL="$GITHUB_REPO"
if [[ -n "$GITHUB_TOKEN" && "$GITHUB_REPO" == https://* ]]; then
  REPO_URL="${GITHUB_REPO/https:\/\//https://${GITHUB_TOKEN}@}"
fi

# 1) Dump MongoDB
log "Starting MongoDB dump..."
mongodump --uri="$MONGODB_URI" --archive="$DUMP_FILE" --gzip --quiet
log "Dump created: $(du -h "$DUMP_FILE" | cut -f1)"

# 2) Clone the repo (shallow, single branch)
log "Cloning repository..."
if ! git clone --depth 1 --branch "$GIT_BRANCH" "$REPO_URL" "$REPO_DIR" 2>/dev/null; then
  # Branch may not exist yet (empty repo) -> init manually
  log "Branch '$GIT_BRANCH' not found; initializing fresh repo."
  mkdir -p "$REPO_DIR"
  git -C "$REPO_DIR" init -q -b "$GIT_BRANCH"
  git -C "$REPO_DIR" remote add origin "$REPO_URL"
fi

# 3) Create NEW directory and copy the backup in
DEST_DIR="$REPO_DIR/$BACKUP_ROOT_DIR/$TIMESTAMP"
mkdir -p "$DEST_DIR"

FILE_SIZE_MB=$(( $(stat -c%s "$DUMP_FILE") / 1024 / 1024 ))
if (( FILE_SIZE_MB > MAX_FILE_MB )); then
  log "Backup is ${FILE_SIZE_MB}MB (> ${MAX_FILE_MB}MB); splitting into chunks..."
  split -b "${MAX_FILE_MB}M" -d "$DUMP_FILE" "$DEST_DIR/$(basename "$DUMP_FILE").part_"
  cat > "$DEST_DIR/RESTORE.txt" <<EOF
Backup was split because of GitHub's file size limit. To restore:
  cat $(basename "$DUMP_FILE").part_* > $(basename "$DUMP_FILE")
  mongorestore --uri="<your-uri>" --archive=$(basename "$DUMP_FILE") --gzip
EOF
else
  cp "$DUMP_FILE" "$DEST_DIR/"
fi

# 4) Commit and push
cd "$REPO_DIR"
git config user.name  "$GIT_USER_NAME"
git config user.email "$GIT_USER_EMAIL"
git add "$BACKUP_ROOT_DIR/$TIMESTAMP"
git commit -q -m "MongoDB backup $TIMESTAMP"

log "Pushing to GitHub..."
git push -q origin "$GIT_BRANCH"

log "Done. Backup stored in: $BACKUP_ROOT_DIR/$TIMESTAMP"
