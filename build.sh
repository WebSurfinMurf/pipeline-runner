#!/usr/bin/env bash

cd /home/websurfinmurf/projects/pipeline-runner
sleep 10
docker stop pipeline-runner 2>/dev/null || true
sleep 10
docker rm   pipeline-runner 2>/dev/null || true
sleep 10
git pull origin main
sleep 10
docker build --no-cache -t websurfinmurf/pipeline-runner:latest .
sleep 10
docker push websurfinmurf/pipeline-runner:latest
sleep 10
docker run -d   --name pipeline-runner   --env-file /home/websurfinmurf/projects/secrets/pipeline.env  -v /home/websurfinmurf/projects/pipeline-runner:/pipeline-runner -v /var/run/docker.sock:/var/run/docker.sock   websurfinmurf/pipeline-runner:latest
