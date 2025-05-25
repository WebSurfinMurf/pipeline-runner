FROM docker:24.0-cli
RUN apk add --no-cache git bash

# set this as the default inside-container cwd
WORKDIR /pipeline-runner/repos/pipeline-runner

# copy your entire repo here
COPY . /pipeline-runner

RUN chmod +x pipeline.sh
RUN addgroup -S appuser && adduser  -S appuser -G appuser && mkdir -p /app && chown -R appuser:appuser /app


# 2) drop privileges for everything that follows
USER appuser
ENTRYPOINT ["bash","pipeline.sh"]
