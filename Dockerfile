# Use your existing base image (docker:24.0-cli is Alpine-based)
FROM docker:24.0-cli
RUN apk add --no-cache git bash # Or other necessary packages for your base image

# Arguments to pass in the UIDs and GIDs from the host
# Replace default values with the actual values you got from `id apprunner`
ARG IN_CONTAINER_APPRUNNER_UID=1001
ARG IN_CONTAINER_APPRUNNER_PRIMARY_GID=1001
ARG IN_CONTAINER_DOCKER_SOCKET_GID=999

# Create a group inside the container for Docker socket access.
# This group will have the same GID as the host's 'docker' group.
# Using -S for system group, -g to specify GID.
RUN addgroup -S -g ${IN_CONTAINER_DOCKER_SOCKET_GID} csocketaccessgroup

# Create the primary group for the 'apprunner' user inside the container.
RUN addgroup -S -g ${IN_CONTAINER_APPRUNNER_PRIMARY_GID} apprunnerprimarygroup

# Create the 'apprunner' user inside the container.
# -S for system user (no password, locked)
# -u to specify UID
# -G to specify the primary group (name)
# -h to set home directory
# -s to set shell
RUN adduser -S -u ${IN_CONTAINER_APPRUNNER_UID} -G apprunnerprimarygroup -h /home/apprunner -s /bin/bash apprunner && \
    adduser apprunner csocketaccessgroup # Add user 'apprunner' to the container's socket access group

# Set the working directory
WORKDIR /pipeline-runner

# Copy application files and set ownership to the new 'apprunner' user and its primary group
#COPY --chown=apprunner:apprunnerprimarygroup . .
# Alternatively, using UIDs:
# COPY --chown=${IN_CONTAINER_APPRUNNER_UID}:${IN_CONTAINER_APPRUNNER_PRIMARY_GID} . .

# Ensure your script is executable
RUN chmod +x pipeline.sh

# Switch to the 'apprunner' user for subsequent commands and as the default user for the container
USER apprunner

# Define the entrypoint
ENTRYPOINT ["bash", "pipeline.sh"]
