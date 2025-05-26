#!/usr/bin/env bash
set -x # This is good for debugging!

# Navigate to your project directory
cd /home/websurfinmurf/projects/pipeline-runner

# Stop and remove the old container if it exists
docker stop pipeline-runner 2>/dev/null || true
docker rm   pipeline-runner 2>/dev/null || true

# Get the latest code, including your Dockerfile
git pull origin main

# --- ADD THESE LINES TO GET HOST IDs ---
# Ensure the 'apprunner' user and 'docker' group exist on your host first!
# If 'apprunner' user doesn't exist, create it: sudo adduser apprunner
# If 'apprunner' is not in 'docker' group, add it: sudo usermod -aG docker apprunner
# (The apprunner user needs to log out/in for group changes to take effect in their shell,
# but for 'id' and 'getent' commands run by root/sudo or another user, it's immediate)

HOST_APPRUNNER_UID=$(id -u apprunner)
HOST_APPRUNNER_PRIMARY_GID=$(id -g apprunner)
HOST_DOCKER_SOCKET_GID=$(getent group docker | cut -d: -f3) # GID of the 'docker' GROUP on host

# Check if the commands above were successful
if [ -z "$HOST_APPRUNNER_UID" ] || [ -z "$HOST_APPRUNNER_PRIMARY_GID" ] || [ -z "$HOST_DOCKER_SOCKET_GID" ]; then
    echo "Error: Could not retrieve UID/GID for apprunner or docker group."
    echo "Please ensure user 'apprunner' exists and you have permissions to run 'id' and 'getent'."
    exit 1
fi

echo "Building with:"
echo "  Apprunner UID: $HOST_APPRUNNER_UID"
echo "  Apprunner Primary GID: $HOST_APPRUNNER_PRIMARY_GID"
echo "  Docker Socket GID: $HOST_DOCKER_SOCKET_GID"
# --- END OF ADDED LINES ---

# Build the Docker image, passing the UIDs/GIDs as build arguments
# Ensure the ARG names here match exactly what's in your Dockerfile
docker build \
  --no-cache \
  --force-rm \
  --build-arg IN_CONTAINER_APPRUNNER_UID=${HOST_APPRUNNER_UID} \
  --build-arg IN_CONTAINER_APPRUNNER_PRIMARY_GID=${HOST_APPRUNNER_PRIMARY_GID} \
  --build-arg IN_CONTAINER_DOCKER_SOCKET_GID=${HOST_DOCKER_SOCKET_GID} \
  -t websurfinmurf/pipeline-runner:latest .

# Optional: Verify user creation in the new image before pushing/running
echo "Verifying user 'apprunner' in image /etc/passwd:"
docker run --rm websurfinmurf/pipeline-runner:latest cat /etc/passwd | grep apprunner
echo "Verifying user 'apprunner' effective ID in image:"
docker run --rm websurfinmurf/pipeline-runner:latest su - apprunner -c "whoami && id"


# Push the image (optional, if you use a registry)
docker push websurfinmurf/pipeline-runner:latest

# Run the container
# The --user apprunner flag is technically redundant if 'USER apprunner' is correctly
# set as the last USER instruction in your Dockerfile, but it doesn't hurt.
docker run -d \
  --name pipeline-runner \
  --user apprunner \
  --env-file /home/websurfinmurf/projects/secrets/pipeline.env \
  -v /home/websurfinmurf/projects:/projects \
  -v /var/run/docker.sock:/var/run/docker.sock \
  websurfinmurf/pipeline-runner:latest

echo "Script finished. Check container status with 'docker ps -a | grep pipeline-runner' and logs with 'docker logs pipeline-runner'."
