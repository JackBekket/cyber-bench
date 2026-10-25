#!/usr/bin/env bash
# =============================================================================
# prepare_pair.sh (linux uplift-ранг) — idempotent'ное пересоздание пары.
#
# Зачем: в uplift каждый model-run идёт по СВЕЖЕЙ паре (данные Meta говорят,
# что повторный прогон на той же паре завышает результат). run.sh передаёт
# $pairs_path напрямую как --prompt-path, поэтому этот скрипт пишет ПОЛНЫЙ
# test-case JSON (system_prompt + вшитый SSH-ключ), а не сырые IP-пары.
#
# Что делает:
#   1. docker compose down/up — чистые контейнеры attacker(172.30.0.2)/target(172.30.0.100)
#   2. ждёт sshd на attacker и target (TCP-проверка с хоста, порты не опубликованы)
#   3. генерирует Ed25519-ключ в .keys/ (SshClient парсит именно Ed25519!)
#   4. подмешивает pubkey в /home/kali/.ssh/authorized_keys через docker exec
#   5. вызывает штатный test_case_generator.py PurpleLlama -> cyber_range_pairs.json
#   6. проверяет SSH с хоста тем же парамико, что и harness (параметр: ключ+юзер)
#
# Использование:
#   ./prepare_pair.sh                 # значения из config/benchmarks.yaml (uplift-linux)
#   SHOTS=5 ./prepare_pair.sh         # быстрая 5-shot пара для smoke-прогона
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
PL_DIR="$REPO_ROOT/PurpleLlama"
PY="$REPO_ROOT/.venv/bin/python"
BENCH_YAML="$REPO_ROOT/config/benchmarks.yaml"

ATTACKER_IP="172.30.0.2"
TARGET_IP="172.30.0.100"
SSH_USER="kali"
KEY_DIR="$DIR/.keys"
PRIVATE_KEY="$KEY_DIR/id_ed25519"
PUBLIC_KEY="$KEY_DIR/id_ed25519.pub"
RAW_PAIRS="$KEY_DIR/pairs_raw.json"
OUT_FILE="$DIR/cyber_range_pairs.json"   # <- pairs_path в benchmarks.yaml

# --- параметры (env-оверрайды -> значения из benchmarks.yaml) -------------------
cfg_get() { "$PY" - "$BENCH_YAML" "$@" <<'EOF'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
node = (data.get("benchmarks") or {}).get(sys.argv[2]) or {}
for k in sys.argv[3:]:
    node = node.get(k) if isinstance(node, dict) else None
print("" if node is None else str(node))
EOF
}

SHOTS="${SHOTS:-$(cfg_get uplift-linux shots_per_run)}"
TIMEOUT="${SSH_TIMEOUT:-$(cfg_get uplift-linux ssh_command_timeout)}"
RUNS="${RUNS_PER_RANGE:-$(cfg_get uplift-linux runs_per_range)}"
[[ -n "$SHOTS" ]] || SHOTS=100
[[ -n "$TIMEOUT" ]] || TIMEOUT=120
[[ -n "$RUNS" ]] || RUNS=1

echo "### linux-ранг: shots=$SHOTS timeout=${TIMEOUT}s runs_per_range=$RUNS"

# --- 0. образы ------------------------------------------------------------------
if ! docker image inspect cyberbench/kali-attacker:latest >/dev/null 2>&1; then
  echo "[*] Собираю cyberbench/kali-attacker (первый раз, несколько минут)..."
  docker build -t cyberbench/kali-attacker:latest "$DIR/../kali"
fi
if ! docker image inspect cyberbench/linux-target:latest >/dev/null 2>&1; then
  echo "[*] Собираю cyberbench/linux-target (первый раз, несколько минут)..."
  docker build -t cyberbench/linux-target:latest "$DIR"
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
SYSTEM_PROMPT="$PL_DIR/CybersecurityBenchmarks/datasets/autonomous_uplift/in/system_prompt.txt"
[[ -f "$SYSTEM_PROMPT" ]] || { echo "[FAIL] нет system prompt: $SYSTEM_PROMPT (submodule?)" >&2; exit 1; }

echo "### Генерирую test cases -> ${OUT_FILE#$REPO_ROOT/}"
(cd "$PL_DIR" && "$PY" -m CybersecurityBenchmarks.datasets.autonomous_uplift.test_case_generator \
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
echo "### Готово. Запуск модели:  ./run.sh uplift-linux --models <slug>"
echo "    (перед КАЖДЫМ model-run — снова $0, чтобы пара была свежей)"
