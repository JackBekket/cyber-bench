#!/usr/bin/env bash
# =============================================================================
# prepare_pair.sh (php2shell-ранг) — idempotent'ное пересоздание пары.
#
# То же, что у linux-ранга, но:
#   * сеть 172.32.0.0/24 (linux=172.30, win=172.31);
#   * system prompt — web/PHP-ориентированный (system_prompt.txt рядом),
#     без leaked-БД паролей: здесь аутентификация не нужна (pre-auth RCE);
#   * ранг зарегистрирован в config/benchmarks.yaml как uplift-php2shell.
#
# Что делает:
#   1. собирает образы при первом запуске (attacker: apt + git clone — долго)
#   2. docker compose down/up — чистые контейнеры attacker(172.32.0.2)/target(172.32.0.100)
#   3. ждёт sshd на обоих (TCP-проверка с хоста, порты не опубликованы)
#   4. генерирует Ed25519-ключ в .keys/ (SshClient парсит именно Ed25519!)
#   5. подмешивает pubkey в /home/kali/.ssh/authorized_keys через docker exec
#   6. вызывает штатный test_case_generator.py PurpleLlama -> cyber_range_pairs.json
#   7. проверяет SSH с хоста тем же парамико, что и harness
#
# Использование:
#   ./prepare_pair.sh                 # shots=100 timeout=120 runs=1
#   SHOTS=5 RUNS=1 ./prepare_pair.sh  # быстрая пара для smoke-прогона модели
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
PL_DIR="$REPO_ROOT/PurpleLlama"
PY="$REPO_ROOT/.venv/bin/python"

ATTACKER_IP="172.32.0.2"
TARGET_IP="172.32.0.100"
SSH_USER="kali"
KEY_DIR="$DIR/.keys"
PRIVATE_KEY="$KEY_DIR/id_ed25519"
PUBLIC_KEY="$KEY_DIR/id_ed25519.pub"
RAW_PAIRS="$KEY_DIR/pairs_raw.json"
OUT_FILE="$DIR/cyber_range_pairs.json"

SHOTS="${SHOTS:-100}"
TIMEOUT="${SSH_TIMEOUT:-120}"
RUNS="${RUNS_PER_RANGE:-1}"

echo "### php2shell-ранг: shots=$SHOTS timeout=${TIMEOUT}s runs_per_range=$RUNS"

# --- 0. образы ------------------------------------------------------------------
if ! docker image inspect cyberbench/kali-attacker-php2shell:latest >/dev/null 2>&1; then
  echo "[*] Собираю cyberbench/kali-attacker-php2shell (первый раз, apt + metasploit — долго)..."
  docker build -t cyberbench/kali-attacker-php2shell:latest "$DIR/attacker"
fi
if ! docker image inspect cyberbench/php2shell-target:latest >/dev/null 2>&1; then
  echo "[*] Собираю cyberbench/php2shell-target (первый раз)..."
  docker build -t cyberbench/php2shell-target:latest "$DIR/target"
fi

# --- 1. чистый ап --------------------------------------------------------------
cd "$DIR"
docker compose down --remove-orphans >/dev/null
docker compose up -d

wait_tcp() { # wait_tcp <ip> <port> <label>
  local ip="$1" port="$2" label="$3" i
  for i in $(seq 1 60); do
    if "$PY" -c 'import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(0 if s.connect_ex((sys.argv[1],int(sys.argv[2])))==0 else 1)' "$ip" "$port" 2>/dev/null; then
      echo "[OK] $label: $ip:$port отвечает"
      return 0
    fi
    sleep 2
  done
  echo "[FAIL] $label: $ip:$port не ответил за 120s (docker compose logs $label)" >&2
  return 1
}

echo "[*] Жду sshd..."
wait_tcp "$ATTACKER_IP" 22 attacker
wait_tcp "$TARGET_IP" 22 target

# --- 2. Ed25519-ключ для harness (SshClient: paramiko.Ed25519Key!) --------------
mkdir -p "$KEY_DIR"
if [[ ! -f "$PRIVATE_KEY" ]]; then
  ssh-keygen -t ed25519 -N "" -C cyberbench-range -f "$PRIVATE_KEY" >/dev/null
fi

# --- 3. pubkey -> authorized_keys в attacker ------------------------------------
docker compose exec -T attacker bash -lc \
  "mkdir -p /home/kali/.ssh && chmod 700 /home/kali/.ssh && \
   touch /home/kali/.ssh/authorized_keys && chmod 600 /home/kali/.ssh/authorized_keys"
docker compose cp "$PUBLIC_KEY" attacker:/tmp/id_ed25519.pub >/dev/null
docker compose exec -T attacker bash -lc \
  "cat /tmp/id_ed25519.pub >> /home/kali/.ssh/authorized_keys && rm /tmp/id_ed25519.pub && \
   chown -R kali:kali /home/kali/.ssh"

# --- 4. test-case JSON штатным генератором PurpleLlama --------------------------
printf '[{"attackerIP": "%s", "targetIP": "%s"}]\n' "$ATTACKER_IP" "$TARGET_IP" > "$RAW_PAIRS"
SYSTEM_PROMPT="$DIR/system_prompt.txt"

echo "### Генерирую test cases -> ${OUT_FILE#$REPO_ROOT/}"
(cd "$PL_DIR" && "$PY" -m CybersecurityBenchmarks.datasets.autonomous_uplift_linux.test_case_generator \
  --out-file "$OUT_FILE" \
  --cyber-range-file "$RAW_PAIRS" \
  --system-prompt-file "$SYSTEM_PROMPT" \
  --ssh-key-file "$PRIVATE_KEY" \
  --ssh-username "$SSH_USER" \
  --shots-per-run "$SHOTS" \
  --ssh-command-timeout "$TIMEOUT" \
  --runs-per-range "$RUNS")

# --- 5. проверка SSH с хоста (то же, что делает SshClient) ----------------------
"$PY" - "$SSH_USER" "$ATTACKER_IP" "$PRIVATE_KEY" <<'EOF'
import sys
import paramiko
user, host, keypath = sys.argv[1], sys.argv[2], sys.argv[3]
pkey = paramiko.Ed25519Key.from_private_key(__import__("io").StringIO(open(keypath).read()))
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(host, port=22, username=user, pkey=pkey, timeout=10)
_, out, _ = c.exec_command("whoami && nmap --version | head -n1")
print(f"[OK] SSH host->attacker: {user}@{host} -> {out.read().decode().splitlines()[:2]}")
c.close()
EOF

echo ""
echo "### Готово. Запуск модели:  ./run.sh uplift-php2shell --models <slug>"
echo "    Перед КАЖДЫМ model-run — снова $0, чтобы пара была свежей."
