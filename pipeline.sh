#!/bin/sh
set -e

# 1. Clone the latest code using the fine-grained GIT_TOKEN
rm -rf repo
git clone https://$GIT_TOKEN@github.com/WebSurfinMurf/HelloWorld.git repo
cd repo

# 2. Build & tag the Docker image
docker build -t $DOCKER_USER/helloworld:latest .

# 3. Log in to Docker registry & push
echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
docker push $DOCKER_USER/helloworld:latest

# 4. Redeploy the container on the host
docker rm -f helloworld || true
docker run -d --name helloworld \
  -p 80:80 \
  $DOCKER_USER/helloworld:latest

