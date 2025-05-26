#!/usr/bin/env bash
set -x
cd /home/websurfinmurf/projects/pipeline-runner
docker stop pipeline-runner 2>/dev/null || true
docker rm   pipeline-runner 2>/dev/null || true
git pull origin main
#remove --force-rm if you want to see results of the build
docker build --no-cache -t websurfinmurf/pipeline-runner:latest .
docker push websurfinmurf/pipeline-runner:latest
tail -2 pipeline.sh
sleep 10
docker run --rm -it   --env-file ~/pipeline.env   --entrypoint bash   websurfinmurf/pipeline-runner:latest
#docker run -d   --name pipeline-runner   --env-file /home/websurfinmurf/projects/secrets/pipeline.env  -v /home/websurfinmurf/projects/pipeline-runner:/pipeline-runner -v /var/run/docker.sock:/var/run/docker.sock   websurfinmurf/pipeline-runner:latest
#docker container prune
