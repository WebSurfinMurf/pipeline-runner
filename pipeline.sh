#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/pipeline.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== $(date) Starting pipeline ====="

WORK_BASE="$SCRIPT_DIR/repos"
mkdir -p "$WORK_BASE"

while IFS='|' read -r KEY GIT_URL IMAGE_NAME CONTAINER_NAME PORT; do
  [[ -z "$KEY" || "${KEY:0:1}" == "#" ]] && continue

  echo
  echo "⏳ Processing [$KEY]"

  REPO_DIR="$WORK_BASE/$KEY"
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    # first-time clone
    echo "🔗 Cloning $KEY"
    git clone "$(eval echo $GIT_URL)" "$REPO_DIR"
  else
    # existing clone → pull
    echo "🔄 Pulling latest for $KEY"
    pushd "$REPO_DIR" >/dev/null
    PULL_OUT=$(git pull --ff-only origin main 2>&1 || true)
    popd >/dev/null

    if echo "$PULL_OUT" | grep -q "Already up to date."; then
      echo "↩️  $KEY is already up to date, skipping build/deploy"
      continue
    else
      echo "✨  Updates detected in $KEY, proceeding to build"
    fi
  fi

  # Build → Push → Deploy
  pushd "$REPO_DIR" >/dev/null
  echo "🚧 Building image: $DOCKER_USER/$IMAGE_NAME:latest"
  docker build -t "$DOCKER_USER/$IMAGE_NAME:latest" .

  echo "🔐 Logging into Docker Hub"
  echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin

  echo "📤 Pushing image"
  docker push "$DOCKER_USER/$IMAGE_NAME:latest"

  echo "🔄 Deploying container: $CONTAINER_NAME → host port $PORT"
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  docker run -d --name "$CONTAINER_NAME" -p "$PORT:$PORT" "$DOCKER_USER/$IMAGE_NAME:latest"
  popd >/dev/null

  echo "✅ Done with [$KEY]"

done < "$SCRIPT_DIR/pipeline.conf"

echo
echo "===== $(date) Pipeline complete ====="
