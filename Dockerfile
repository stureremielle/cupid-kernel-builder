# Reproducible build environment for the cupid kernel builder.
#
#   docker build -t cupid-kernel-builder .
#   docker run --rm -it -v "${PWD}:/project" -w /project \
#       cupid-kernel-builder --work-dir /project/work --from-device
#
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

COPY scripts/install-deps.sh /tmp/install-deps.sh
RUN bash /tmp/install-deps.sh && rm -f /tmp/install-deps.sh

# adb is optional; only needed for --from-device (requires USB passthrough)
RUN apt-get update && \
    apt-get install -y --no-install-recommends adb && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /project
ENTRYPOINT ["bash", "/project/build.sh"]
CMD ["--help"]
