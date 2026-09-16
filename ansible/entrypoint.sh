#!/usr/bin/env bash
# Container entrypoint.
#
# Bind-mounted SSH keys from a Windows host typically come in with 0777-ish
# permissions, which OpenSSH rejects ("Permissions ... are too open"). Copy
# them into a writable location with 0600 / 0700 so ssh accepts them.
# Same treatment for the OCI CLI config (which contains the private API
# signing key -- `oci` warns if it's world-readable).

set -euo pipefail

if [[ -d /mnt/ssh ]]; then
    mkdir -p /root/.ssh
    cp -rT /mnt/ssh /root/.ssh
    chmod 700 /root/.ssh
    find /root/.ssh -type f -exec chmod 600 {} \;
fi

if [[ -d /mnt/oci ]]; then
    mkdir -p /root/.oci
    cp -rT /mnt/oci /root/.oci
    chmod 700 /root/.oci
    find /root/.oci -type f -exec chmod 600 {} \;
fi

exec "$@"
