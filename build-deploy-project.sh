#!/usr/bin/env bash
set -euo pipefail # Exit on error, undefined variable, pipe failure
# set -x # Uncomment for detailed debugging during development

# --- Logging Function ---
log() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $*"
}

# --- Configuration and Initial Setup ---
TARGET_HOST_USER="websurfinmurf" # The user context for file ownership and running containers
HOST_DOCKER_GROUP="docker"     # The host group that typically owns /var/run/docker.sock

# Base directory for all projects and secrets on the host
HOST_MAIN_PROJECTS_DIR="/home/${TARGET_HOST_USER}/projects"

# Global pipeline environment file (expected to contain DOCKER_USER, DOCKER_PASS, GIT_TOKEN etc.)
GLOBAL_PIPELINE_ENV_FILE="${HOST_MAIN_PROJECTS_DIR}/secrets/pipeline.env"

# Source global .env file if it exists
if [[ -f "$GLOBAL_PIPELINE_ENV_FILE" ]]; then
  log "Sourcing global environment from $GLOBAL_PIPELINE_ENV_FILE"
  set -a # Automatically export all variables subsequently defined or sourced
  # shellcheck source=/dev/null
  source "$GLOBAL_PIPELINE_ENV_FILE"
  set +a
else
  log "Warning: Global pipeline env file not found at $GLOBAL_PIPELINE_ENV_FILE."
  log "Ensure required variables (DOCKER_USER, DOCKER_PASS, etc.) are set in the environment or this file."
fi

# Check for required variables (expected from sourced file or pre-existing environment)
: "${DOCKER_USER:?Error: DOCKER_USER environment variable is required. Set it in $GLOBAL_PIPELINE_ENV_FILE or the environment.}"
: "${DOCKER_PASS:?Error: DOCKER_PASS environment variable is required. Set it in $GLOBAL_PIPELINE_ENV_FILE or the environment.}"
# GIT_TOKEN is optional, checked later if used.

# Script configuration
SCRIPT_DIR_ON_HOST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # Directory where this script resides on the host
CONF_FILE="${SCRIPT_DIR_ON_HOST}/pipeline.conf" # Assumes pipeline.conf is in the same directory as this script

BRANCH="${BRANCH:-main}" # Default git branch if not set by environment

# Validate TARGET_PROJECT_KEY argument (passed by GitHub Actions or when called manually)
if [ $# -lt 1 ]; then
  log "ERROR: No project specified to build and deploy."
  log "Usage: $0 <TARGET_PROJECT_KEY>"
  exit 1
fi
TARGET_PROJECT_KEY="$1"
log "🎯 Target project key received: $TARGET_PROJECT_KEY"

# Validate pipeline.conf
if [[ ! -f "$CONF_FILE" ]]; then
  log "ERROR: Cannot find pipeline.conf at $CONF_FILE" >&2
  exit 1
fi

### --- Get Host UIDs/GIDs for TARGET_HOST_USER and HOST_DOCKER_GROUP --- ###
log "Fetching UIDs/GIDs for host user '$TARGET_HOST_USER' and group '$HOST_DOCKER_GROUP'..."

if ! id -u "$TARGET_HOST_USER" > /dev/null 2>&1; then
    log "Error: Host user '$TARGET_HOST_USER' does not exist. This script is intended to be run by or for this user."
    exit 1
fi
if ! getent group "$HOST_DOCKER_GROUP" > /dev/null 2>&1; then
    log "Error: Host group '$HOST_DOCKER_GROUP' does not exist. This group is needed for Docker socket permissions."
    exit 1
fi
# Ensure the TARGET_HOST_USER is part of the HOST_DOCKER_GROUP (for running Docker commands without sudo)
if ! id -nG "$TARGET_HOST_USER" | grep -qw "$HOST_DOCKER_GROUP"; then
    log "Warning: Host user '$TARGET_HOST_USER' is not part of the '$HOST_DOCKER_GROUP' group."
    log "Docker commands might require sudo or fail if this script isn't run by root."
    log "To fix, run: sudo usermod -aG ${HOST_DOCKER_GROUP} ${TARGET_HOST_USER} (and then ${TARGET_HOST_USER} must log out/in)."
    # Depending on how this script is run (as root or as websurfinmurf), this might or might not be an issue for *this script's* docker commands.
    # However, it's crucial for the container's Docker socket access if the container user relies on group GID.
fi

HOST_TARGET_USER_UID=$(id -u "$TARGET_HOST_USER")
HOST_TARGET_USER_PRIMARY_GID=$(id -g "$TARGET_HOST_USER") # Primary GID of TARGET_HOST_USER on host
HOST_DOCKER_SOCKET_GID=$(getent group "$HOST_DOCKER_GROUP" | cut -d: -f3) # GID of the 'docker' GROUP on host

log "Host UIDs/GIDs to be used for container builds/runs (user: $TARGET_HOST_USER):"
log "  Target User UID (IN_CONTAINER_USER_UID): $HOST_TARGET_USER_UID"
log "  Target User Primary GID (IN_CONTAINER_USER_PRIMARY_GID): $HOST_TARGET_USER_PRIMARY_GID"
log "  Docker Group GID (IN_CONTAINER_DOCKER_SOCKET_GID): $HOST_DOCKER_SOCKET_GID"

### --- Docker Login (once) --- ###
log "Attempting Docker Hub login as $DOCKER_USER..."
if echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin; then
  log "Docker login successful."
else
  log "ERROR: Docker login failed."
  exit 1
fi

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

  # Define project-specific paths on the HOST system
  PROJECT_CODE_DIR="${HOST_MAIN_PROJECTS_DIR}/${REPO_KEY}"
  PROJECT_ENV_FILE="${HOST_MAIN_PROJECTS_DIR}/secrets/${REPO_KEY}.env"

  log "Project code directory (host path): $PROJECT_CODE_DIR"
  log "Project-specific .env file (host path): $PROJECT_ENV_FILE"

  ### 1. Git Clone or Pull Project Repository ###
  mkdir -p "$(dirname "$PROJECT_CODE_DIR")" # Ensure parent of project code dir exists
  if [[ -d "$PROJECT_CODE_DIR/.git" ]]; then
    log "Pulling latest for $REPO_KEY (branch $BRANCH) in $PROJECT_CODE_DIR..."
    # Ensure operations are done as TARGET_HOST_USER if script is run by root
    # If script is already run as TARGET_HOST_USER, sudo -u is not strictly needed but harmless if user can sudo to self
    # For simplicity, assuming the script is run by TARGET_HOST_USER or a user with appropriate perms
    (cd "$PROJECT_CODE_DIR" && git fetch origin && git reset --hard "origin/$BRANCH" && git clean -fdx) || { log "ERROR: Git pull failed for $REPO_KEY."; exit 1; }
  else
    log "Cloning $REPO_KEY (branch $BRANCH) from $GIT_URL into $PROJECT_CODE_DIR..."
    EFFECTIVE_GIT_URL="$GIT_URL"
    if [[ -n "${GIT_TOKEN:-}" ]]; then # Check if GIT_TOKEN is set and not empty
      if [[ $GIT_URL == https://* ]]; then
        EFFECTIVE_GIT_URL="https://${GIT_TOKEN}@${GIT_URL#https://}"
        log "Using token for Git clone."
      else
        log "Warning: GIT_TOKEN provided but GIT_URL ($GIT_URL) is not HTTPS. Cloning without token."
      fi
    fi
    git clone --depth 1 --branch "$BRANCH" "$EFFECTIVE_GIT_URL" "$PROJECT_CODE_DIR" || { log "ERROR: Git clone failed for $REPO_KEY."; exit 1; }
    # If script was run as root, ensure TARGET_HOST_USER owns the cloned repo
    # This is important if the script is invoked by a root-like CI agent but needs user-level ownership
    # If the script is run by TARGET_HOST_USER, this chown is redundant.
    # sudo chown -R "${TARGET_HOST_USER}:${TARGET_HOST_USER}" "$PROJECT_CODE_DIR" # Uncomment if necessary
  fi

  ### 2. Build Docker Image for the Project ###
  # Assumes Dockerfile is in the root of $PROJECT_CODE_DIR
  # This Dockerfile MUST be prepared to accept UID/GID ARGs to create an internal user
  # that maps to the host's TARGET_HOST_USER.
  FULL_IMAGE_NAME="${DOCKER_USER}/${IMAGE_NAME}:latest"
  log "Building Docker image $FULL_IMAGE_NAME from context $PROJECT_CODE_DIR..."
  docker build --no-cache --pull --force-rm \
    --build-arg GIT_TOKEN="${GIT_TOKEN:-}" \
    --build-arg IN_CONTAINER_USER_UID="${HOST_TARGET_USER_UID}" \
    --build-arg IN_CONTAINER_USER_PRIMARY_GID="${HOST_TARGET_USER_PRIMARY_GID}" \
    --build-arg IN_CONTAINER_DOCKER_SOCKET_GID="${HOST_DOCKER_SOCKET_GID}" \
    -t "$FULL_IMAGE_NAME" "$PROJECT_CODE_DIR" || { log "ERROR: Docker build failed for $FULL_IMAGE_NAME."; exit 1; }

  ### 3. Push Docker Image ###
  log "Pushing image $FULL_IMAGE_NAME to Docker Hub..."
  docker push "$FULL_IMAGE_NAME" || { log "ERROR: Docker push failed for $FULL_IMAGE_NAME."; exit 1; }

  ### 4. Deploy Project Container ###
  log "Deploying container '$CONTAINER_NAME' from image $FULL_IMAGE_NAME..."
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true # Stop/remove if already running

  DOCKER_RUN_OPTIONS=("-d" "--name" "$CONTAINER_NAME" "--restart" "unless-stopped")

  # Run the container process as the host TARGET_HOST_USER's UID and primary GID.
  # The project's Dockerfile is responsible for creating an internal user with these IDs
  # and ensuring it's also part of a group with GID HOST_DOCKER_SOCKET_GID for Docker socket access.
  DOCKER_RUN_OPTIONS+=(--user "${HOST_TARGET_USER_UID}:${HOST_TARGET_USER_PRIMARY_GID}")

  # Project-specific .env file (using host path)
  if [[ -f "$PROJECT_ENV_FILE" ]]; then
    log "Attaching project-specific .env file: $PROJECT_ENV_FILE"
    DOCKER_RUN_OPTIONS+=(--env-file "$PROJECT_ENV_FILE")
  else
    log "Warning: Project-specific .env file not found at $PROJECT_ENV_FILE. Container '$CONTAINER_NAME' will run without it."
  fi

  # Port mapping from pipeline.conf
  if [[ -n "$PORT" && "$PORT" != "N/A" && "$PORT" != "NONE" && "$PORT" != "" ]]; then # Ensure PORT is valid and not empty
    log "Mapping port $PORT for container '$CONTAINER_NAME'"
    DOCKER_RUN_OPTIONS+=("-p" "${PORT}:${PORT}") # Assumes internal and external port are the same
  else
    log "No valid port mapping specified for container '$CONTAINER_NAME'."
  fi

  # Mount Docker socket (allowing the project container to use Docker if its Dockerfile set up permissions)
  DOCKER_RUN_OPTIONS+=("-v" "/var/run/docker.sock:/var/run/docker.sock")

  # Optional: Mount project code if needed by the running container (e.g., for development or dynamic content)
  # If the image is self-contained, this might not be needed.
  # DOCKER_RUN_OPTIONS+=("-v" "${PROJECT_CODE_DIR}:/app:ro") # Example: mount to /app read-only

  log "Attempting to run container '$CONTAINER_NAME' with options: ${DOCKER_RUN_OPTIONS[*]}"
  docker run "${DOCKER_RUN_OPTIONS[@]}" "$FULL_IMAGE_NAME" || { log "ERROR: Failed to run container $CONTAINER_NAME."; exit 1; }

  log "✅ Successfully deployed $REPO_KEY as container '$CONTAINER_NAME'."
  break # Exit loop after processing the target project
done < "$CONF_FILE"

if ! $PROJECT_FOUND; then
  log "⚠️ ERROR: Target project key '$TARGET_PROJECT_KEY' not found in $CONF_FILE."
  exit 1
fi

log "Pipeline script finished successfully for project $TARGET_PROJECT_KEY."
