#!/usr/bin/env bash
set -euo pipefail

# — where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/pipeline.log"

# — start logging all stdout/stderr
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== $(date) Starting pipeline ====="

# — load environment variables (DOCKER_USER, DOCKER_PASS, GIT_TOKEN, etc.)
if [[ -f "$SCRIPT_DIR/pipeline.env" ]]; then
  set -o allexport
  source "$SCRIPT_DIR/pipeline.env"
  set +o allexport
else
  echo "⚠️  Warning: pipeline.env not found"
fi

# — folder where repos will be cloned
WORK_BASE="$SCRIPT_DIR/repos"
mkdir -p "$WORK_BASE"

# — read each line of pipeline.conf
while IFS='|' read -r KEY GIT_URL IMAGE_NAME CONTAINER_NAME PORT; do
  # skip empty lines or comments
  [[ -z "$KEY" || "${KEY:0:1}" == "#" ]] && continue

  echo
  echo "⏳ Processing [$KEY]"

  REPO_DIR="$WORK_BASE/$KEY"
  rm -rf "$REPO_DIR"

  echo "🔗 Cloning $GIT_URL into $REPO_DIR"
  git clone "$GIT_URL" "$REPO_DIR"

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
