#!/usr/bin/env bash
# =============================================================================
# prepare_pair.sh (win uplift-ранг) — idempotent'ное пересоздание пары.
# Аналог linux/prepare_pair.sh для Windows-таргета по спеке Meta:
#   attacker = 172.31.0.2 (Kali), target = 172.31.0.100 (Windows Server 2022).
#
# Требования к хосту: KVM (/dev/kvm) + /dev/net/tun — таргет это настоящая ВМ
#   (dockurr/windows, KVM-ускорение), НЕ qemu-user/binfmt. Скрипт проверяет
#   устройства сам и падает с понятным сообщением до compose up.
#
# Использование:
#   ./prepare_pair.sh                 # значения из config/benchmarks.yaml (uplift-win)
#   SHOTS=5 ./prepare_pair.sh         # быстрая 5-shot пара для smoke-прогона
#   FRESH=1 ./prepare_pair.sh         # стереть диск ранг-ВМ -> чистая установка Windows
#                                     #   (~30–60 мин первого бута; *.iso сохраняются,
#                                     #   чтобы не докачивать ISO ~5GB)
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
PL_DIR="$REPO_ROOT/PurpleLlama"
PY="$REPO_ROOT/.venv/bin/python"
BENCH_YAML="$REPO_ROOT/config/benchmarks.yaml"

ATTACKER_IP="172.31.0.2"
TARGET_IP="172.31.0.100"
SSH_USER="kali"
KEY_DIR="$DIR/.keys"
PRIVATE_KEY="$KEY_DIR/id_ed25519"
PUBLIC_KEY="$KEY_DIR/id_ed25519.pub"
RAW_PAIRS="$KEY_DIR/pairs_raw.json"
OUT_FILE="$DIR/cyber_range_pairs.json"   # <- pairs_path в benchmarks.yaml

cfg_get() { "$PY" - "$BENCH_YAML" "$@" <<'EOF'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
node = (data.get("benchmarks") or {}).get(sys.argv[2]) or {}
for k in sys.argv[3:]:
    node = node.get(k) if isinstance(node, dict) else None
print("" if node is None else str(node))
EOF
}

SHOTS="${SHOTS:-$(cfg_get uplift-win shots_per_run)}"
TIMEOUT="${SSH_TIMEOUT:-$(cfg_get uplift-win ssh_command_timeout)}"
RUNS="${RUNS_PER_RANGE:-$(cfg_get uplift-win runs_per_range)}"
[[ -n "$SHOTS" ]] || SHOTS=100
[[ -n "$TIMEOUT" ]] || TIMEOUT=120
[[ -n "$RUNS" ]] || RUNS=1

echo "### win-ранг: shots=$SHOTS timeout=${TIMEOUT}s runs_per_range=$RUNS"

# --- 0. KVM + TUN -----------------------------------------------------------------
# Таргет — настоящая ВМ под KVM (dockurr/windows): qemu-user/binfmt больше не нужен.
if [[ ! -c /dev/kvm ]]; then
  echo "[FAIL] нет /dev/kvm — Windows-ВМ поднимется только без ускорения (TCG, очень медленно)." >&2
  echo "       Включите KVM: sudo usermod -aG kvm,$(id -un) + новый login, либо см. win/README.md." >&2
  exit 1
fi
if [[ ! -c /dev/net/tun ]]; then
  echo "[FAIL] нет /dev/net/tun — dockurr/windows не построит macvtap для гостя." >&2
  exit 1
fi

# --- 0b. FRESH=1: стирание диска ранг-ВМ ------------------------------------------
# Убирает data.img и OVMF/UEFI-метаданные -> чистая установка Windows с нуля.
# *.iso сохраняются, чтобы не докачивать ~5GB ISO из Microsoft повторно.
STORAGE_DIR="/media/bekket/AC662A65662A310E/cyberbench/win-range-storage"
if [[ "${FRESH:-0}" == "1" ]]; then
  mkdir -p "$STORAGE_DIR"
  echo "[*] FRESH=1: стираю $STORAGE_DIR (data.img + windows.*), *.iso сохраняются"
  rm -f "$STORAGE_DIR"/data.img "$STORAGE_DIR"/windows.base \
        "$STORAGE_DIR"/windows.boot "$STORAGE_DIR"/windows.mac \
        "$STORAGE_DIR"/windows.rom "$STORAGE_DIR"/windows.vars "$STORAGE_DIR"/windows.ver
fi

# --- 1. образы -------------------------------------------------------------------
if ! docker image inspect cyberbench/kali-attacker:latest >/dev/null 2>&1; then
  echo "[*] Собираю cyberbench/kali-attacker..."
  docker build -t cyberbench/kali-attacker:latest "$DIR/../kali"
fi
if ! docker image inspect cyberbench/win-target:latest >/dev/null 2>&1; then
  echo "[FAIL] Нет образа cyberbench/win-target:latest. Соберите (см. win/README.md):" >&2
  echo "       docker build -t cyberbench/win-target:latest $DIR" >&2
  exit 1
fi

# --- 2. чистый ап -----------------------------------------------------------------
cd "$DIR"
docker compose down --remove-orphans >/dev/null
docker compose up -d

wait_tcp() { # wait_tcp <ip> <port> <label> <max_seconds> [poll_seconds]
  local ip="$1" port="$2" label="$3" max="${4:-120}" poll="${5:-2}" i=0
  while (( i < max )); do
    if "$PY" -c 'import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(0 if s.connect_ex((sys.argv[1],int(sys.argv[2])))==0 else 1)' "$ip" "$port" 2>/dev/null; then
      echo "[OK] $label: $ip:$port отвечает (через ${i}s)"
      return 0
    fi
    sleep "$poll"; (( i += poll ))
  done
  echo "[FAIL] $label: $ip:$port не ответил за ${max}s (docker compose logs $label)" >&2
  return 1
}

echo "[*] Жду sshd..."
wait_tcp "$ATTACKER_IP" 22 attacker 300

# Windows-таргет: ждём OpenSSH (:22) — RDP/SMB не нужны harness'у (только модели).
# Чистая установка Windows занимает ~30–60 минут; на живом диске бут ~1–2 минуты.
if [[ "${FRESH:-0}" == "1" ]] || [[ ! -f "$STORAGE_DIR/data.img" ]]; then
  echo "[*] Файл диска не найден или FRESH=1 — жду ЧИСТУЮ установку Windows (до 75 минут)..."
  wait_tcp "$TARGET_IP" 22 target 4500 15
else
  echo "[*] Живой диск найден — обычный бут (до 10 минут)..."
  wait_tcp "$TARGET_IP" 22 target 600 10
fi

# --- 3. Ed25519-ключ для harness (SshClient: paramiko.Ed25519Key!) ----------------
mkdir -p "$KEY_DIR"
if [[ ! -f "$PRIVATE_KEY" ]]; then
  ssh-keygen -t ed25519 -N "" -C cyberbench-range -f "$PRIVATE_KEY" >/dev/null
fi

docker compose exec -T attacker bash -lc \
  "mkdir -p /home/kali/.ssh && chmod 700 /home/kali/.ssh && \
   touch /home/kali/.ssh/authorized_keys && chmod 600 /home/kali/.ssh/authorized_keys"
docker compose cp "$PUBLIC_KEY" attacker:/tmp/id_ed25519.pub >/dev/null
docker compose exec -T attacker bash -lc \
  "cat /tmp/id_ed25519.pub >> /home/kali/.ssh/authorized_keys && rm /tmp/id_ed25519.pub && \
   chown -R kali:kali /home/kali/.ssh"

# --- 4. test-case JSON штатным генератором PurpleLlama ----------------------------
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

# --- 5. проверка SSH с хоста (то же, что делает SshClient) ------------------------
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
echo "### Готово. Запуск модели:  ./run.sh uplift-win --models <slug>"
echo "    (перед КАЖДЫМ model-run — снова $0, чтобы пара была свежей)"
