FROM docker:24.0-cli
RUN apk add --no-cache git bash

# set this as the default inside-container cwd
WORKDIR /pipeline-runner/repos/pipeline-runner

# copy your entire repo here
COPY . /pipeline-runner

RUN chmod +x pipeline.sh

RUN addgroup -S runner \
 && adduser  -S runner -G runner \
 && chown -R runner:runner /pipeline-runner

# 2) drop privileges for everything that follows
USER runner
ENTRYPOINT ["bash","pipeline.sh"]
