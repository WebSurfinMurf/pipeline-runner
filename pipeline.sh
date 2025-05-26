#!/usr/bin/env bash
set -euo pipefail
echo "starting directory"
pwd

# AI:  Do not LOAD "$HOME/pipeline.env, and its inherited at run time using this syntax, typical command used
# AI: docker run -d   --name pipeline-runner   --env-file ~/pipeline.env   -v /var/run/docker.sock:/var/run/docker.sock   pipeline-runner:latest

### 0) Required DockerHub creds from --env-file ###
: "${DOCKER_USER:?DOCKER_USER is required (from pipeline.env)}"
: "${DOCKER_PASS:?DOCKER_PASS is required (from pipeline.env)}"
																 
BRANCH="${BRANCH:-main}"

# bail if no project key was passed
if [ $# -lt 1 ]; then
  echo "ERROR: No project specified."
  echo "Usage: $0 <project_key>"
  exit 1
fi

# Store the target project key from the first argument
TARGET_PROJECT_KEY="$1"

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
echo "Logging in to Docker Hub as $DOCKER_USER"
echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin

echo "🎯 Target project key specified: $TARGET_PROJECT_KEY" # Log the target

### 4) Loop through each pipeline.conf entry ###
PROJECT_FOUND=false # Flag to check if the target project was found
while IFS='|' read -r REPO_KEY GIT_URL IMAGE_NAME CONTAINER_NAME PORT || [[ -n "$REPO_KEY" ]]; do
  # skip blank lines or comments
  [[ -z "$REPO_KEY" || "${REPO_KEY:0:1}" == "#" ]] && continue

  # <<< --- ADD THIS CHECK --- >>>
  # If the REPO_KEY from the file does not match the TARGET_PROJECT_KEY, skip it
  if [[ "$REPO_KEY" != "$TARGET_PROJECT_KEY" ]]; then
    # Optional: You can log that you're skipping other projects
    # log "Skipping project: $REPO_KEY (target is $TARGET_PROJECT_KEY)"
    continue
  fi
  # <<< --- END OF CHECK --- >>>

  PROJECT_FOUND=true # Mark that we found and are processing the target project
  echo "🔄 Processing project: $REPO_KEY"
  CLONE_DIR="/projects/$REPO_KEY"

  ### 4a) Clone or pull (injecting $GIT_TOKEN at runtime) ###
  if [[ -d "$CLONE_DIR/.git" ]]; then
    echo " Pulling latest for $REPO_KEY (branch=$BRANCH)"
    cd "$CLONE_DIR"
    git pull origin "$BRANCH"
  else
    host_and_path="${GIT_URL#https://}"
    if [[ -n "${GIT_TOKEN:-}" ]]; then
      CLONE_URL="https://${GIT_TOKEN}@${host_and_path}"
      echo " Cloning with token → $CLONE_URL"
    else
      CLONE_URL="$GIT_URL"
      echo " Cloning without auth → $CLONE_URL"
    fi
    git clone "$CLONE_URL" "$CLONE_DIR"
    cd "$CLONE_DIR"
  fi
  echo "CLONE_DIR $CLONE_DIR ,  GIT_URL $GIT_URL, BRANCH $BRANCH, CLONE_URL $CLONE_URL"
  ### 4b) Echo the README.md if present ###
  if [[ -f "README.md" ]]; then
    echo " —— Contents of README.md ——"
    sed 's/^/    /' README.md # Indent README content
    echo " —— End README.md ——"
  else
    echo " (no README.md found)"
  fi

  ### 4c) Build the Docker image (no cache) ###
										
  FULL_IMAGE="${DOCKER_USER}/${IMAGE_NAME}:latest"
  echo " Building Docker image $FULL_IMAGE"
  docker build --no-cache --pull \
    --force-rm \
    --build-arg GIT_TOKEN="${GIT_TOKEN:-}" \
    -t "$FULL_IMAGE" .

  ### 4d) Push to Docker Hub ###
  echo " Pushing $FULL_IMAGE"
  docker push "$FULL_IMAGE"
  echo "current"
  pwd
  ls -ltr
  
  ### 4e) Deploy via direct Docker (no Portainer) ###
  #  --env-file /home/websurfinmurf/secrets/pipeline.env \
  #   -v /projects/"$REPO_KEY":/"$REPO_KEY" \
  echo " Deploying container '$CONTAINER_NAME' on port $PORT"
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  docker run -d \
    --name "$CONTAINER_NAME" \
    --env-file /projects/secrets/$REPO_KEY.env \
    --user websurfinmurf:docker \
    -p "$PORT":"$PORT" \
    "$FULL_IMAGE" # Corrected a potential typo in your original volume mount, ensuring projectS with an S

  echo "✅ $REPO_KEY done"
  # Since we found and processed the target project, we can exit the loop
  # If you expect multiple entries with the same REPO_KEY and want to process all, remove the 'break'
  break 
done < "$CONF_FILE"

# After the loop, check if the targeted project was actually found and processed
if ! $PROJECT_FOUND; then
  echo "⚠️ ERROR: Project key '$TARGET_PROJECT_KEY' not found in $CONF_FILE."
  exit 1 # Exit with an error if the specified project key was not in the conf file
fi

echo "Pipeline finished for project $TARGET_PROJECT_KEY."
