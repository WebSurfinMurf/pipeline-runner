#!/usr/bin/env bash

cd /home/websurfinmurf/projects/pipeline-runner
docker stop pipeline-runner 2>/dev/null || true
docker rm   pipeline-runner 2>/dev/null || true
git pull origin main
docker build --no-cache -t websurfinmurf/pipeline-runner:latest .
docker push websurfinmurf/pipeline-runner:latest
docker run -d   --name pipeline-runner   --env-file ~/secrets/pipeline.env  -v /home/websurfinmurf/projects:/pipeline-runner/repos -v /var/run/docker.sock:/var/run/docker.sock   websurfinmurf/pipeline-runner:latest
