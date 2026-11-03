# =============================================================================
# cyberbench win-target — Windows Server 2022 Datacenter (KVM) на базе dockurr/windows.
#
#   docker build -t cyberbench/win-target:latest .
#
# Что делает образ поверх dockurr/windows:
#   * /oem/setup.ps1  — сценарий подготовки таргета (пользователи FrankFurter/
#                       PaigeTurner, OpenSSH-сервер :22, SMB-шеры FSERVER01/DATABOX).
#                       getOemFolder() в dockurr отдаёт приоритет /oem над $STORAGE/oem —
#                       bind-mount'ы не нужны, гонок при старте нет.
#   * /oem/install.bat  — генерируется из oem/install.bat.tpl: маркер __PAYLOAD_B64__
#                          заменяется base64-кодом setup.ps1 (CRLF через unix2dos).
#                          На ЧИСТОЙ установке в C:\OEM добирается ТОЛЬКО install.bat
#                          (overlay ISO копирует лишь его), поэтому payload встраивается
#                          прямо в него: install.bat расписывает setup.ps1 и запускает.
#
# Первый логон гостя полностью unattended (AutoLogon Docker, LogonCount=65432):
# FirstLogonCommands -> Unattend.cmd :logon -> OEM_SCRIPT блок -> C:\OEM\install.bat.
# С LOG=Y в compose dockurr заменяет OEM_SCRIPT на вариант с редиректом вывода в
# C:\OEM\install.log (enableLog, answer.sh) — дебаг установки без noVNC.
# =============================================================================

FROM dockurr/windows@sha256:16fd7c39a3e48bb946d29c59dc6015942e5b900a1fa5d7e5552053bfc48ee2ea

COPY oem/setup.ps1 /oem/setup.ps1
# Шаблон install.bat подхватываем в образ только для генерации (удаляем после).
COPY oem/install.bat.tpl /tmp/install.bat.tpl
RUN set -eu; \
    [ -f /run/assets/win2022.cmd ] || { echo "[FAIL] нет /run/assets/win2022.cmd — изменился образ dockurr/windows" >&2; exit 1; }; \
    PAYLOAD_B64="$(base64 -w0 /oem/setup.ps1)"; \
    # Делитель '|' безопасен: base64-алфавит не содержит '|', '&' и '\' (спецсимволы s-команды).
    sed "s|__PAYLOAD_B64__|${PAYLOAD_B64}|g" /tmp/install.bat.tpl | unix2dos > /oem/install.bat; \
    if grep -q '__PAYLOAD_B64__' /oem/install.bat; then echo "[FAIL] __PAYLOAD_B64__ не подставлен" >&2; exit 1; fi; \
    [ -s /oem/install.bat ] || { echo "[FAIL] /oem/install.bat пустой" >&2; exit 1; }; \
    rm -f /tmp/install.bat.tpl; \
    echo "[OK] /oem/install.bat: $(wc -c < /oem/install.bat) bytes (payload b64: ${#PAYLOAD_B64})"; \
    head -n 5 /oem/install.bat

