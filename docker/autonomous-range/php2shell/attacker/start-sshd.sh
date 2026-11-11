#!/bin/bash
# Attacker entrypoint: гарантировать host keys + /run/sshd, затем sshd foreground.
set -e
mkdir -p /run/sshd
ssh-keygen -A >/dev/null 2>&1 || true
exec /usr/sbin/sshd -D -e
