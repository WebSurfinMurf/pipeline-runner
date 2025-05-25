#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------
# build.sh — build & deploy pipeline-runner
# ----------------------------------------

# Navigate to the pipeline-runner project dir
cd /home/websurfinmurf/projects/pipeline-runner

# 1) Stop any existing pipeline-runner container
if docker ps --filter "name=pipeline-runner" -q | grep -q .; then
  echo "[INFO] Stopping existing pipeline-runner container..."
  docker stop pipeline-runner
fi

# 2) Remove any existing pipeline-runner container
if docker ps -a --filter "name=pipeline-runner" -q | grep -q .; then
  echo "[INFO] Removing existing pipeline-runner container..."
  docker rm pipeline-runner
fi

# 3) Sync code from GitHub
echo "[INFO] Pulling latest code from GitHub..."
git pull origin main

# 4) Build the Docker image (no cache)
echo "[INFO] Building Docker image websurfinmurf/pipeline-runner:latest..."
docker build --no-cache -t websurfinmurf/pipeline-runner:latest .

# 5) Push the new image to Docker Hub
echo "[INFO] Pushing Docker image to Docker Hub..."
docker push websurfinmurf/pipeline-runner:latest

# 6) Deploy pipeline-runner container
#    --rm: auto-remove when the script inside exits (prevents stray containers)
#    --name: fixed name to avoid Docker random naming
#    Pass no parameters so pipeline.sh exits early (no projects)
echo "[INFO] Deploying pipeline-runner container..."
docker run --rm -d \
  --name pipeline-runner \
  --env-file /home/websurfinmurf/projects/secrets/pipeline.env \
  -v $(pwd):/pipeline-runner \
  -v /var/run/docker.sock:/var/run/docker.sock \
  websurfinmurf/pipeline-runner:latest

echo "[INFO] pipeline-runner container started (and will auto-clean up on exit)."
