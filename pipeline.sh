#!/usr/bin/env bash
set -euo pipefail

# AI:  Do not LOAD "$HOME/pipeline.env, and its inherited at run time using this syntax, typical command used
# AI: docker run -d   --name pipeline-runner   --env-file ~/pipeline.env   -v /var/run/docker.sock:/var/run/docker.sock   pipeline-runner:latest
# AI: 1) Environment has the  secrets & tokens defined.

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
  # skip blank lines or comments
  [[ -z "$REPO_KEY" || "${REPO_KEY:0:1}" == "#" ]] && continue

  log "🔄 Processing project: $REPO_KEY"

  CLONE_DIR="$HOME/$REPO_KEY"

  # 4a) Clone or update, injecting GIT_TOKEN at runtime
  if [[ -d "$CLONE_DIR/.git" ]]; then
    log " Pulling latest for $REPO_KEY"
    cd "$CLONE_DIR"
    git pull origin "${BRANCH:-main}"
  else
    # remove protocol prefix
    url_no_proto="${GIT_URL#https://}"
    # if there's an '@' (embedded creds), strip up to it
    if [[ "$url_no_proto" == *@* ]]; then
      host_and_path="${url_no_proto#*@}"
    else
      host_and_path="$url_no_proto"
    fi
    # inject the real token
    clone_url="https://${GIT_TOKEN}@${host_and_path}"
    log " Cloning $clone_url → $CLONE_DIR"
    git clone "$clone_url" "$CLONE_DIR"
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
