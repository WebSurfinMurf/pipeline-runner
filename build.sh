#!/usr/bin/env bash

cd /home/websurfinmurf/projects/pipeline-runner
git pull origin main
docker stop pipeline-runner 2>/dev/null || true
docker rm   pipeline-runner 2>/dev/null || true
docker build --no-cache -t websurfinmurf/pipeline-runner:latest .
docker run -d   --name pipeline-runner   --env-file ~/pipeline.env  -v /home/websurfinmurf/projects:/pipeline-runner/repos -v /var/run/docker.sock:/var/run/docker.sock   pipeline-runner:latest
