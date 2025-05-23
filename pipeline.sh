#!/usr/bin/env bash
set -euo pipefail

# AI:  Do not LOAD "$HOME/pipeline.env, and its inherited at run time using this syntax, typical command used
# AI: docker run -d   --name pipeline-runner   --env-file ~/pipeline.env   -v /var/run/docker.sock:/var/run/docker.sock   pipeline-runner:latest

########## 0) Ensure required env vars from --env-file ##########
: "${DOCKER_USER:?DOCKER_USER is required (from pipeline.env)}"
: "${DOCKER_PASS:?DOCKER_PASS is required (from pipeline.env)}"
: "${PORTAINER_HOST:?PORTAINER_HOST is required (from pipeline.env)}"
: "${ENDPOINT_ID:?ENDPOINT_ID is required (from pipeline.env)}"
: "${PORTAINER_TOKEN:?PORTAINER_TOKEN is required (from pipeline.env)}"
# GIT_TOKEN is optional; if unset, clones will be unauthenticated
BRANCH="${BRANCH:-main}"

########## 1) Locate pipeline.conf next to this script ##########
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/pipeline.conf"
if [[ ! -f "$CONF_FILE" ]]; then
  echo "ERROR: Cannot find $CONF_FILE" >&2
  exit 1
fi

########## 2) Simple logger ##########
log() { echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $*"; }

########## 3) Loop through each line of pipeline.conf :contentReference[oaicite:0]{index=0} ##########
while IFS='|' read -r REPO_KEY GIT_URL IMAGE_NAME CONTAINER_NAME PORT || [[ -n "$REPO_KEY" ]]; do
  # skip blanks or comments
  [[ -z "$REPO_KEY" || "${REPO_KEY:0:1}" == "#" ]] && continue

  log "🔄 Processing project: $REPO_KEY"
  CLONE_DIR="$HOME/$REPO_KEY"

  ########## 3a) Clone or pull, injecting GIT_TOKEN at runtime ##########
  if [[ -d "$CLONE_DIR/.git" ]]; then
    log " Pulling latest for $REPO_KEY (branch=$BRANCH)"
    cd "$CLONE_DIR"
    git pull origin "$BRANCH"
  else
    # strip leading protocol
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

  ########## 3b) Echo the README.md if present ##########
  if [[ -f "README.md" ]]; then
    log " —— Contents of README.md ——"
    sed 's/^/    /' README.md
    log " —— End README.md ——"
  else
    log " (no README.md found)"
  fi

  ########## 3c) Build the Docker image (no cache) ##########
  FULL_IMAGE="${DOCKER_USER}/${IMAGE_NAME}:latest"
  log " Building Docker image $FULL_IMAGE"
  docker build --no-cache \
    --build-arg GIT_TOKEN="${GIT_TOKEN:-}" \
    -t "$FULL_IMAGE" .

  ########## 3d) Show PATH inside the new image ##########
  log " PATH inside image $FULL_IMAGE:"
  docker run --rm "$FULL_IMAGE" printenv PATH

  ########## 3e) Push to Docker Hub :contentReference[oaicite:2]{index=2} ##########
  log " Pushing $FULL_IMAGE"
  echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
  docker push "$FULL_IMAGE"

  ########## 3f) Trigger Portainer to load the new image ##########
  log " Deploying $FULL_IMAGE on endpoint $ENDPOINT_ID"
  curl -s -X POST \
    "http://${PORTAINER_HOST}/api/endpoints/${ENDPOINT_ID}/docker/images/${DOCKER_USER}/${IMAGE_NAME}:latest/load" \
    -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
    || { log "ERROR: Portainer deploy failed for $IMAGE_NAME"; exit 1; }

  log "✅ $REPO_KEY done"
done < "$CONF_FILE"
