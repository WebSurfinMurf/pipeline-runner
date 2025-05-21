FROM docker:24.0-cli
RUN apk add --no-cache git bash
WORKDIR /pipeline
COPY pipeline.sh .
ENTRYPOINT ["./pipeline.sh"]
