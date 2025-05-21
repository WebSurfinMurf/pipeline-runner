#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/pipeline.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== $(date) Starting pipeline ====="

# — no more sourcing pipeline.env; Docker passed your env vars already

WORK_BASE="$SCRIPT_DIR/repos"
mkdir -p "$WORK_BASE"

while IFS='|' read -r KEY GIT_URL IMAGE_NAME CONTAINER_NAME PORT; do
  [[ -z "$KEY" || "${KEY:0:1}" == "#" ]] && continue

  echo
  echo "⏳ Processing [$KEY]"

  REPO_DIR="$WORK_BASE/$KEY"
  rm -rf "$REPO_DIR"

  # ← expand the variable in the URL so $GIT_TOKEN is replaced
  CLONE_URL=$(eval "echo $GIT_URL")
  echo "🔗 Cloning $CLONE_URL into $REPO_DIR"
  git clone "$CLONE_URL" "$REPO_DIR"

  cd "$REPO_DIR"

  echo "🚧 Building image: $DOCKER_USER/$IMAGE_NAME:latest"
  docker build -t "$DOCKER_USER/$IMAGE_NAME:latest" .

  echo "🔐 Logging into Docker Hub"
  echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin

  echo "📤 Pushing image"
  docker push "$DOCKER_USER/$IMAGE_NAME:latest"

  echo "🔄 Deploying container: $CONTAINER_NAME → host port $PORT"
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  docker run -d --name "$CONTAINER_NAME" -p "$PORT:$PORT" "$DOCKER_USER/$IMAGE_NAME:latest"

  echo "✅ Done with [$KEY]"
done < "$SCRIPT_DIR/pipeline.conf"

echo
echo "===== $(date) Pipeline complete ====="
