# Linux container that runs Ansible / molecule / oci-cli for operators on a
# Windows host (or any host without a working Ansible controller). Same shape
# as the bluedoter controller image: the `[dependency-groups.deploy]` venv is
# built at image-build time and put on PATH; at runtime the repo is
# bind-mounted at /workspace.
#
# Build context expected: repo root (set in ansible/docker-compose.yml).

ARG UV_BASE_IMAGE=ghcr.io/astral-sh/uv:python3.14-bookworm-slim
FROM ${UV_BASE_IMAGE}

# openssh-client: Ansible's SSH transport.
# git / curl / ca-certificates: galaxy + goss downloads.
# dnsutils: `dig` for the smoke checks against the public nameserver.
# openssl: derive DKIM public keys from the private keys + STARTTLS probes.
# build-essential: oci-cli -> crc32c has no CPython 3.14 wheel yet and is
#   compiled from sdist.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        openssh-client \
        ca-certificates \
        git \
        curl \
        dnsutils \
        openssl \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY pyproject.toml uv.lock ./

# Build the deploy venv outside /workspace so the runtime bind-mount doesn't
# shadow it.
ENV UV_PROJECT_ENVIRONMENT=/opt/dns-smtp-server-venv \
    UV_PYTHON_DOWNLOADS=never \
    UV_LINK_MODE=copy

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --group deploy --no-default-groups

# oci-cli as an isolated uv tool: its pins must not constrain the Ansible venv.
# The oracle.oci collection only needs the `oci` SDK, which is in uv.lock.
ENV UV_TOOL_DIR=/opt/uv-tools \
    UV_TOOL_BIN_DIR=/usr/local/bin
RUN --mount=type=cache,target=/root/.cache/uv \
    uv tool install "oci-cli>=3.50"

COPY ansible/requirements.yml /tmp/requirements.yml
RUN /opt/dns-smtp-server-venv/bin/ansible-galaxy collection install -r /tmp/requirements.yml \
        --collections-path /usr/share/ansible/collections \
    && rm /tmp/requirements.yml

# goss: the static binary is published directly (no tarball); download and
# sha256-verify the pinned asset.
ARG GOSS_VERSION=v0.4.9
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) goss_arch='amd64'; goss_sha='87dd36cfa1b8b50554e6e2ca29168272e26755b19ba5438341f7c66b36decc19' ;; \
        arm64) goss_arch='arm64'; goss_sha='14fd24ac08236559f4809e6a627792d1b947ed98654bba1662ef1d6122d77e18' ;; \
        *) echo "unsupported architecture for goss: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 30 \
        -o /usr/local/bin/goss \
        "https://github.com/goss-org/goss/releases/download/${GOSS_VERSION}/goss-linux-${goss_arch}"; \
    echo "${goss_sha}  /usr/local/bin/goss" | sha256sum -c -; \
    chmod +x /usr/local/bin/goss; \
    goss --version

# Docker CLI: molecule's docker driver talks to the mounted /var/run/docker.sock
# through `docker exec`, so the client binary must exist here. Only the client
# is installed -- the daemon is the host's. Kept last so the expensive layers
# above stay cached.
RUN set -eux; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL --retry 5 --retry-all-errors --connect-timeout 30 \
        https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc; \
    chmod a+r /etc/apt/keyrings/docker.asc; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends docker-ce-cli; \
    rm -rf /var/lib/apt/lists/*; \
    docker --version

WORKDIR /workspace

ENV PATH="/opt/dns-smtp-server-venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    ANSIBLE_HOST_KEY_CHECKING=False \
    ANSIBLE_COLLECTIONS_PATH=/usr/share/ansible/collections

COPY ansible/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
