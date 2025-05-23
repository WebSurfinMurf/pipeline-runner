#!/usr/bin/env bash
set -euo pipefail

set -euo pipefail

# 1) Load secrets & variables from your home env file
if [ -f "$HOME/pipeline.env" ]; then
  # shellcheck disable=SC1090
  source "$HOME/pipeline.env"
else
  echo "ERROR: Cannot find $HOME/pipeline.env; did you upload it?" >&2
  exit 1
fi

# Simple logger
log() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $*"
}

# Iterate through each repo/service defined in pipeline.conf
for SERVICE in "${SERVICES[@]}"; do
  REPO_DIR="$WORK_DIR/$SERVICE"
  
  # 1) Clone or update
  if [ -d "$REPO_DIR" ]; then
    log "Updating ${SERVICE}..."
    cd "$REPO_DIR"
    git pull origin "$BRANCH"
  else
    log "Cloning ${SERVICE}..."
    git clone "https://github.com/${GITHUB_ORG}/${SERVICE}.git" "$REPO_DIR"
    cd "$REPO_DIR"
  fi

  # ——— Echo whatever README.* (any case/ext) to the log ———
  README_FILE=$(find . -maxdepth 1 -type f -iname 'readme.*' | head -n1 || true)
  if [ -n "$README_FILE" ]; then
    log "==== Contents of ${SERVICE}/${README_FILE} ===="
    sed 's/^/    /' "$README_FILE"
    log "==== End $README_FILE ===="
  else
    log "No README.* found for ${SERVICE}"
  fi

  # 2) Build the Docker image (no cache to ensure freshness)
  IMAGE="${DOCKERHUB_USER}/${SERVICE}:latest"
  log "Building Docker image ${IMAGE}..."
  docker build --no-cache \
    --build-arg GITHUB_TOKEN="${GITHUB_TOKEN}" \
    -t "${IMAGE}" .

  # ——— Your new block: Echo the PATH inside the built image ———
  log ">>> PATH inside ${SERVICE} image:"
  docker run --rm "${IMAGE}" printenv PATH

  # 3) Push the image
  log "Pushing ${IMAGE} to Docker Hub..."
  echo "${DOCKERHUB_PASS}" | docker login -u "${DOCKERHUB_USER}" --password-stdin
  docker push "${IMAGE}"

  # 4) Trigger Portainer deploy
  log "Deploying ${SERVICE} via Portainer..."
  curl -s -X POST \
    "http://${PORTAINER_HOST}/api/endpoints/${ENDPOINT_ID}/docker/images/${IMAGE}/load" \
    -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
    || { log "ERROR: Deployment failed for ${SERVICE}"; exit 1; }

  log "✅ ${SERVICE} deployment complete."
done
