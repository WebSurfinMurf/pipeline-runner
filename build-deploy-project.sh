#!/usr/bin/env bash
set -euo pipefail # Exit on error, undefined variable, pipe failure
# set -x # Uncomment for detailed debugging

log() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $*"
}

### --- Configuration and Initial Setup --- ###
# Base directory for all projects and secrets on the host
HOST_MAIN_PROJECTS_DIR="/home/websurfinmurf/projects"

# Global pipeline environment file (Requirement 1)
GLOBAL_PIPELINE_ENV_FILE="$HOST_MAIN_PROJECTS_DIR/secrets/pipeline.env"

# Source global .env file if it exists
if [[ -f "$GLOBAL_PIPELINE_ENV_FILE" ]]; then
  log "Sourcing global environment from $GLOBAL_PIPELINE_ENV_FILE"
  set -a # Automatically export all variables subsequently defined or sourced
  # shellcheck source=/dev/null
  source "$GLOBAL_PIPELINE_ENV_FILE"
  set +a
else
  log "Warning: Global pipeline env file not found at $GLOBAL_PIPELINE_ENV_FILE. Script might fail if required variables (DOCKER_USER, DOCKER_PASS, etc.) are not set."
fi

# Check for required variables (now expected from the sourced file or pre-existing environment)
: "${DOCKER_USER:?Error: DOCKER_USER environment variable is required (expected from $GLOBAL_PIPELINE_ENV_FILE or environment)}"
: "${DOCKER_PASS:?Error: DOCKER_PASS environment variable is required (expected from $GLOBAL_PIPELINE_ENV_FILE or environment)}"
# GIT_TOKEN is checked later if used

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # Directory where this script resides
CONF_FILE="$SCRIPT_DIR/pipeline.conf" # Assumes pipeline.conf is in the same directory as this script

BRANCH="${BRANCH:-main}" # Default git branch

# Validate TARGET_PROJECT_KEY argument (this will be passed by GitHub Actions)
if [ $# -lt 1 ]; then
  log "ERROR: No project specified to build and deploy."
  log "Usage: $0 <TARGET_PROJECT_KEY>"
  exit 1
fi
TARGET_PROJECT_KEY="$1"

# Validate pipeline.conf
if [[ ! -f "$CONF_FILE" ]]; then
  log "ERROR: Cannot find pipeline.conf at $CONF_FILE" >&2
  exit 1
fi

### --- Get Host UIDs/GIDs for 'apprunner' user and 'docker' group (Requirement 3) --- ###
# These are fetched directly from the host system where this script runs.
HOST_APPRUNNER_USER="apprunner"
HOST_DOCKER_GROUP="docker"

if ! id -u "$HOST_APPRUNNER_USER" > /dev/null 2>&1; then
    log "Error: Host user '$HOST_APPRUNNER_USER' does not exist. Please create it and ensure it's part of the '$HOST_DOCKER_GROUP' group."
    exit 1
fi
if ! getent group "$HOST_DOCKER_GROUP" > /dev/null 2>&1; then
    log "Error: Host group '$HOST_DOCKER_GROUP' does not exist. This group is needed for Docker socket permissions."
    exit 1
fi

HOST_APPRUNNER_UID=$(id -u "$HOST_APPRUNNER_USER")
HOST_APPRUNNER_PRIMARY_GID=$(id -g "$HOST_APPRUNNER_USER") # Primary GID of apprunner on host
HOST_DOCKER_SOCKET_GID=$(getent group "$HOST_DOCKER_GROUP" | cut -d: -f3) # GID of the 'docker' GROUP on host

log "Host UIDs/GIDs for container builds/runs:"
log "  Apprunner User UID: $HOST_APPRUNNER_UID"
log "  Apprunner User Primary GID: $HOST_APPRUNNER_PRIMARY_GID"
log "  Docker Group GID (for socket & group membership): $HOST_DOCKER_SOCKET_GID"

### --- Docker Login (once) --- ###
log "Attempting Docker Hub login as $DOCKER_USER..."
if echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin; then
  log "Docker login successful."
else
  log "ERROR: Docker login failed."
  exit 1
fi

log "🎯 Target project key specified: $TARGET_PROJECT_KEY"

### --- Process Target Project from pipeline.conf --- ###
PROJECT_FOUND=false
# Read pipeline.conf line by line
# Format expected: REPO_KEY|GIT_URL|IMAGE_NAME|CONTAINER_NAME|PORT
while IFS='|' read -r REPO_KEY GIT_URL IMAGE_NAME CONTAINER_NAME PORT || [[ -n "$REPO_KEY" ]]; do
  # Skip blank lines or comments
  [[ -z "$REPO_KEY" || "${REPO_KEY:0:1}" == "#" ]] && continue

  # Process only the target project
  if [[ "$REPO_KEY" != "$TARGET_PROJECT_KEY" ]]; then
    continue
  fi

  PROJECT_FOUND=true
  log "🔄 Processing project: $REPO_KEY (Image: ${DOCKER_USER}/${IMAGE_NAME}, Container: $CONTAINER_NAME, Port: $PORT)"

  # Define project-specific paths on the HOST system (Requirement 4)
  PROJECT_CODE_DIR="$HOST_MAIN_PROJECTS_DIR/$REPO_KEY"
  PROJECT_ENV_FILE="$HOST_MAIN_PROJECTS_DIR/secrets/$REPO_KEY.env" # Requirement 2

  log "Project code directory (host path): $PROJECT_CODE_DIR"
  log "Project-specific .env file (host path): $PROJECT_ENV_FILE"

  ### 1. Git Clone or Pull Project Repository ###
  mkdir -p "$(dirname "$PROJECT_CODE_DIR")"
  if [[ -d "$PROJECT_CODE_DIR/.git" ]]; then
    log "Pulling latest for $REPO_KEY (branch $BRANCH) in $PROJECT_CODE_DIR..."
    (cd "$PROJECT_CODE_DIR" && git fetch origin && git reset --hard "origin/$BRANCH" && git clean -fdx) || { log "ERROR: Git pull failed for $REPO_KEY."; continue; }
  else
    log "Cloning $REPO_KEY (branch $BRANCH) from $GIT_URL into $PROJECT_CODE_DIR..."
    EFFECTIVE_GIT_URL="$GIT_URL"
    if [[ -n "${GIT_TOKEN:-}" ]]; then
      if [[ $GIT_URL == https://* ]]; then
        EFFECTIVE_GIT_URL="https://${GIT_TOKEN}@${GIT_URL#https://}"
        log "Using token for Git clone."
      else
        log "Warning: GIT_TOKEN provided but GIT_URL is not HTTPS for $GIT_URL. Cloning without token."
      fi
    fi
    git clone --depth 1 --branch "$BRANCH" "$EFFECTIVE_GIT_URL" "$PROJECT_CODE_DIR" || { log "ERROR: Git clone failed for $REPO_KEY."; continue; }
  fi

  ### 2. Build Docker Image for the Project ###
  # Assumes Dockerfile is in the root of $PROJECT_CODE_DIR
  # This Dockerfile MUST be prepared to accept UID/GID ARGs to create an 'apprunner' user.
  FULL_IMAGE_NAME="${DOCKER_USER}/${IMAGE_NAME}:latest"
  log "Building Docker image $FULL_IMAGE_NAME from context $PROJECT_CODE_DIR..."
  docker build --no-cache --pull --force-rm \
    --build-arg GIT_TOKEN="${GIT_TOKEN:-}" \
    --build-arg IN_CONTAINER_APPRUNNER_UID="${HOST_APPRUNNER_UID}" \
    --build-arg IN_CONTAINER_APPRUNNER_PRIMARY_GID="${HOST_APPRUNNER_PRIMARY_GID}" \
    --build-arg IN_CONTAINER_DOCKER_SOCKET_GID="${HOST_DOCKER_SOCKET_GID}" \
    -t "$FULL_IMAGE_NAME" "$PROJECT_CODE_DIR" || { log "ERROR: Docker build failed for $FULL_IMAGE_NAME."; continue; }

  ### 3. Push Docker Image ###
  log "Pushing image $FULL_IMAGE_NAME to Docker Hub..."
  docker push "$FULL_IMAGE_NAME" || { log "ERROR: Docker push failed for $FULL_IMAGE_NAME."; continue; }

  ### 4. Deploy Project Container ###
  log "Deploying container '$CONTAINER_NAME' from image $FULL_IMAGE_NAME..."
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

  DOCKER_RUN_OPTIONS=("-d" "--name" "$CONTAINER_NAME")

  # Requirement 3: Run as apprunner user (UID) with its primary group (GID).
  # The project's Dockerfile is responsible for ensuring this user (UID)
  # is also part of a group with GID HOST_DOCKER_SOCKET_GID for Docker socket access.
  DOCKER_RUN_OPTIONS+=(--user "${HOST_APPRUNNER_UID}:${HOST_APPRUNNER_PRIMARY_GID}")

  # Requirement 2: Project-specific .env file (using host path)
  if [[ -f "$PROJECT_ENV_FILE" ]]; then
    log "Attaching project-specific .env file: $PROJECT_ENV_FILE"
    DOCKER_RUN_OPTIONS+=(--env-file "$PROJECT_ENV_FILE")
  else
    log "Warning: Project-specific .env file not found at $PROJECT_ENV_FILE. Container will run without it."
  fi

  # Port mapping from pipeline.conf
  if [[ -n "$PORT" && "$PORT" != "N/A" && "$PORT" != "NONE" ]]; then # Ensure PORT is valid
    log "Mapping port $PORT"
    DOCKER_RUN_OPTIONS+=("-p" "${PORT}:${PORT}")
  fi

  # Mount Docker socket (allowing the project container to use Docker if needed)
  DOCKER_RUN_OPTIONS+=("-v" "/var/run/docker.sock:/var/run/docker.sock")

  # Optional: Mount project code if needed by the running container
  # DOCKER_RUN_OPTIONS+=("-v" "${PROJECT_CODE_DIR}:/app:ro") # Example: mount to /app read-only

  log "Attempting to run container '$CONTAINER_NAME' with options: ${DOCKER_RUN_OPTIONS[*]}"
  docker run "${DOCKER_RUN_OPTIONS[@]}" "$FULL_IMAGE_NAME" || { log "ERROR: Failed to run container $CONTAINER_NAME."; continue; }

  log "✅ Successfully deployed $REPO_KEY as container '$CONTAINER_NAME'."
  break # Exit loop after processing the target project
done < "$CONF_FILE"

if ! $PROJECT_FOUND; then
  log "⚠️ ERROR: Target project key '$TARGET_PROJECT_KEY' not found in $CONF_FILE."
  exit 1
fi

log "Pipeline script finished successfully for project $TARGET_PROJECT_KEY."
