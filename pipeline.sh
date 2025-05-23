#!/usr/bin/env bash
set -euo pipefail

# 1) Load your secrets & tokens
if [[ -f "$HOME/pipeline.env" ]]; then
  # shellcheck disable=SC1090
  source "$HOME/pipeline.env"
else
  echo "ERROR: Cannot find $HOME/pipeline.env" >&2
  exit 1
fi

# 2) Locate pipeline.conf next to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/pipeline.conf"
if [[ ! -f "$CONF_FILE" ]]; then
  echo "ERROR: Cannot find $CONF_FILE" >&2
  exit 1
fi

# 3) Simple logger
log() { echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $*"; }

# 4) Process each line in pipeline.conf
while IFS='|' read -r REPO_KEY GIT_URL IMAGE_NAME CONTAINER_NAME PORT || [[ -n "$REPO_KEY" ]]; do
  # skip blank lines or lines starting with '#'
  [[ -z "$REPO_KEY" || "${REPO_KEY:0:1}" == "#" ]] && continue

  log "🔄 Processing project: $REPO_KEY"

  # where to clone/pull each repo
  CLONE_DIR="$HOME/$REPO_KEY"

  # 4a) Clone or update
  if [[ -d "$CLONE_DIR/.git" ]]; then
    log " Pulling latest for $REPO_KEY"
    cd "$CLONE_DIR"
    git pull origin "${BRANCH:-main}"
  else
    log " Cloning $GIT_URL → $CLONE_DIR"
    git clone "https://${GIT_TOKEN}@${GIT_URL#https://}" "$CLONE_DIR"
    cd "$CLONE_DIR"
  fi

  # 4b) Echo the README.md (if present)
  if [[ -f "README.md" ]]; then
    log " —— Contents of README.md ——"
    sed 's/^/    /' README.md
    log " —— End README.md ——"
  else
    log " (no README.md found)"
  fi

  # 4c) Build the Docker image
  FULL_IMAGE="${DOCKER_USER}/${IMAGE_NAME}:latest"
  log " Building Docker image $FULL_IMAGE"
  docker build --no-cache \
    --build-arg GIT_TOKEN="$GIT_TOKEN" \
    -t "$FULL_IMAGE" .

  # 4d) Show PATH inside the new image
  log " PATH inside $FULL_IMAGE:"
  docker run --rm "$FULL_IMAGE" printenv PATH

  # 4e) Push to Docker Hub
  log " Pushing $FULL_IMAGE"
  echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
  docker push "$FULL_IMAGE"

  # 4f) Trigger Portainer to redeploy
  log " Deploying container '$CONTAINER_NAME' on port $PORT"
  curl -s -X POST \
    "http://${PORTAINER_HOST}/api/endpoints/${ENDPOINT_ID}/docker/containers/${CONTAINER_NAME}/deploy?port=${PORT}" \
    -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
    || { log " ERROR: deployment failed for $CONTAINER_NAME"; exit 1; }

  log "✅ $REPO_KEY DONE"
done < "$CONF_FILE"
