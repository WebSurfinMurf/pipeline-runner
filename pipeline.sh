#!/usr/bin/env bash
set -euo pipefail

# AI:  Do not LOAD "$HOME/pipeline.env, and its inherited at run time using this syntax, typical command used
# AI: docker run -d   --name pipeline-runner   --env-file ~/pipeline.env   -v /var/run/docker.sock:/var/run/docker.sock   pipeline-runner:latest

### 0) Required DockerHub creds from --env-file ###
: "${DOCKER_USER:?DOCKER_USER is required (from pipeline.env)}"
: "${DOCKER_PASS:?DOCKER_PASS is required (from pipeline.env)}"
# GIT_TOKEN is optional; if unset, clones will be unauthenticated
BRANCH="${BRANCH:-main}"

### 1) Locate and validate pipeline.conf ###
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/pipeline.conf"
if [[ ! -f "$CONF_FILE" ]]; then
  echo "ERROR: Cannot find pipeline.conf in $SCRIPT_DIR" >&2
  exit 1
fi

### 2) Simple logger ###
log() { echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $*"; }

### 3) Log in to Docker once ###
log "Logging in to Docker Hub as $DOCKER_USER"
echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin

### 4) Loop through each pipeline.conf entry ###
while IFS='|' read -r REPO_KEY GIT_URL IMAGE_NAME CONTAINER_NAME PORT || [[ -n "$REPO_KEY" ]]; do
  # skip blank lines or comments
  [[ -z "$REPO_KEY" || "${REPO_KEY:0:1}" == "#" ]] && continue

  log "🔄 Processing project: $REPO_KEY"
  CLONE_DIR="$HOME/$REPO_KEY"

  ### 4a) Clone or pull (injecting $GIT_TOKEN at runtime) ###
  if [[ -d "$CLONE_DIR/.git" ]]; then
    log " Pulling latest for $REPO_KEY (branch=$BRANCH)"
    cd "$CLONE_DIR"
    git pull origin "$BRANCH"
  else
    host_and_path="${GIT_URL#https://}"
    if [[ -n "${GIT_TOKEN:-}" ]]; then
      CLONE_URL="https://${GIT_TOKEN}@${host_and_path}"
      log " Cloning with token → $CLONE_URL"
    else
      CLONE_URL="$GIT_URL"
      log " Cloning without auth → $CLONE_URL"
    fi
    git clone "$CLONE_URL" "$CLONE_DIR"
    cd "$CLONE_DIR"
  fi

  ### 4b) Echo the README.md if present ###
  if [[ -f "README.md" ]]; then
    log " —— Contents of README.md ——"
    sed 's/^/    /' README.md
    log " —— End README.md ——"
  else
    log " (no README.md found)"
  fi

  ### 4c) Build the Docker image (no cache) ###
  FULL_IMAGE="${DOCKER_USER}/${IMAGE_NAME}:latest"
  log " Building Docker image $FULL_IMAGE"
  docker build --no-cache \
    --build-arg GIT_TOKEN="${GIT_TOKEN:-}" \
    -t "$FULL_IMAGE" .

  ### 4d) Push to Docker Hub ###
  log " Pushing $FULL_IMAGE"
  docker push "$FULL_IMAGE"

  ### 4e) Deploy via direct Docker (no Portainer) ###
  log " Deploying container '$CONTAINER_NAME' on port $PORT"
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  docker run -d \
    --name "$CONTAINER_NAME" \
    -p "$PORT":"$PORT" \
    -v /home/websurfinmurf/projects/${REPO_KEY}:/home/websurfinmurf/projects/${REPO_KEY} \
    "$FULL_IMAGE"

  log "✅ $REPO_KEY done"
done < "$CONF_FILE"
