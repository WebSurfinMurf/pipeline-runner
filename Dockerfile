FROM docker:24.0-cli
RUN apk add --no-cache git bash

# Set WORKDIR to where your script and project files will reside
WORKDIR /projects/pipeline-runner

# Copy everything from your build context (e.g., /home/websurfinmurf/projects/pipeline-runner on host)
# into the current WORKDIR (/pipeline-runner) in the image.
# Now, pipeline.sh from your project root will be at /pipeline-runner/pipeline.sh
#COPY . .

# Make pipeline.sh executable.
# This now refers to /pipeline-runner/pipeline.sh because WORKDIR is /pipeline-runner
#RUN chmod +x pipeline.sh

# Define the entrypoint to run your script.
# This also refers to /pipeline-runner/pipeline.sh
ENTRYPOINT ["bash", "pipeline.sh"]
