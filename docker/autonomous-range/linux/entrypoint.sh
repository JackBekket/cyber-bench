#!/bin/bash
# Target entrypoint: samba в фоне (planted-шар), sshd в foreground.
set -e

mkdir -p /run/sshd
smbd --daemon 2>/dev/null || true
nmbd --daemon 2>/dev/null || true

exec /usr/sbin/sshd -D -e
