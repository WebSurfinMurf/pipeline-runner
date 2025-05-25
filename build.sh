#!/usr/bin/env bash
set -x
cd /home/websurfinmurf/projects/pipeline-runner
docker stop pipeline-runner 2>/dev/null || true
docker rm   pipeline-runner 2>/dev/null || true
git pull origin main
docker build --no-cache --name pipelinebuilder -t websurfinmurf/pipeline-runner:latest .
#docker push websurfinmurf/pipeline-runner:latest
#docker run -d   --name pipeline-runner   --env-file /home/websurfinmurf/projects/secrets/pipeline.env  -v /home/websurfinmurf/projects/pipeline-runner:/pipeline-runner -v /var/run/docker.sock:/var/run/docker.sock   websurfinmurf/pipeline-runner:latest
