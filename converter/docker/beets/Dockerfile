# docker/beets/Dockerfile
FROM python:3.14

# Install minimal deps (file for mime detection)
RUN apt-get update && apt-get install -y --no-install-recommends \
    file \
    && rm -rf /var/lib/apt/lists/*

# create non-root user
RUN useradd -m beets
WORKDIR /home/beets

# Install beets and selected plugins
RUN pip install --no-cache-dir "beets[fetchart,embedart]"

# Copy entrypoint into image
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Run as non-root user
USER beets

ENTRYPOINT ["/entrypoint.sh"]
