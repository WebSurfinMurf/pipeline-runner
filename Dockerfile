FROM docker:24.0-cli
RUN apk add --no-cache git
WORKDIR /pipeline
COPY pipeline.sh .
ENTRYPOINT ["./pipeline.sh"]
