#!/bin/bash
# Target entrypoint: apache (mod_php) в фоне — это attack surface,
# sshd foreground — канал harness'а (prepare_pair.sh подмешивает ключ).
set -e

mkdir -p /run/sshd
apachectl start 2>/dev/null || service apache2 start

exec /usr/sbin/sshd -D -e
