ARG RUNNER_INSTALLER_IMAGE=ghcr.io/buildbarn/bb-runner-installer:20260417T114310Z-feceee6

FROM ${RUNNER_INSTALLER_IMAGE} AS bb-runner-installer

FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    iptables \
    lsb-release \
    sudo \
    uidmap \
  && install -m 0755 -d /etc/apt/keyrings \
  && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
  && chmod a+r /etc/apt/keyrings/docker.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list \
  && apt-get update && apt-get install -y --no-install-recommends \
    containerd.io \
    docker-buildx-plugin \
    docker-ce \
    docker-ce-cli \
    docker-compose-plugin \
  && rm -rf /var/lib/apt/lists/*

COPY --from=bb-runner-installer /app/bb_runner_installer /usr/local/bin/bb_runner_installer

RUN mkdir -p /bb \
  && /usr/local/bin/bb_runner_installer \
  && test -x /bb/bb_runner \
  && rm /usr/local/bin/bb_runner_installer

RUN groupadd --gid 1000 runner \
  && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash runner \
  && (getent group docker >/dev/null || groupadd docker) \
  && usermod -aG docker runner \
  && echo "runner ALL=(root) NOPASSWD: /usr/bin/dockerd, /usr/bin/chmod, /usr/bin/docker" > /etc/sudoers.d/runner-docker \
  && chmod 0440 /etc/sudoers.d/runner-docker

COPY --chmod=0755 entrypoint.sh /usr/local/bin/sysbox-runner-entrypoint

USER runner
WORKDIR /home/runner
ENTRYPOINT ["/usr/local/bin/sysbox-runner-entrypoint"]
