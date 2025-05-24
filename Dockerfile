FROM docker:24.0-cli
RUN apk add --no-cache git bash

# set this as the default inside-container cwd
WORKDIR /pipeline-runner/repos/pipeline-runner

# copy your entire repo here
COPY . /pipeline-runner

RUN chmod +x pipeline.sh

ENTRYPOINT ["bash","pipeline.sh"]
