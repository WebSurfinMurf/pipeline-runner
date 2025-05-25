#!/usr/bin/env bash

cd /home/websurfinmurf/projects/pipeline-runner
pause 
docker stop pipeline-runner 2>/dev/null || true
pause 
docker rm   pipeline-runner 2>/dev/null || true
pause
git pull origin main
pause
docker build --no-cache -t websurfinmurf/pipeline-runner:latest .
pause
docker push websurfinmurf/pipeline-runner:latest
pause
docker run -d   --name pipeline-runner   --env-file /home/websurfinmurf/projects/secrets/pipeline.env  -v /home/websurfinmurf/projects/pipeline-runner:/pipeline-runner -v /var/run/docker.sock:/var/run/docker.sock   websurfinmurf/pipeline-runner:latest
