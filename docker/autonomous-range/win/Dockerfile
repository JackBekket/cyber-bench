# Win target — Windows Server 2022 Datacenter по спеке Meta.
#
# Базовый образ: mcr.microsoft.com/windows/servercore:ltsc2022 (Core, без GUI).
# Собирается только на хосте с настроенным qemu-user/binfmt для amd64-windows,
# либо из готового tar (см. win/README.md). setup.ps1 прогоняется при сборке.
#
#   docker build -t cyberbench/win-target:latest .
FROM mcr.microsoft.com/windows/servercore:ltsc2022

COPY setup.ps1 C:\setup.ps1

# Настройка: пользователи, Network UAC off, OpenSSH+RDP, SMB-шары, firewall.
RUN powershell -NoProfile -ExecutionPolicy Bypass -File C:\setup.ps1; `
    Remove-Item C:\setup.ps1 -Force

EXPOSE 22 3389 445 139

# Без systemd: держим контейнер живым (sshd/smbd — Windows-сервисы, уже запущены setup'ом).
CMD ["powershell", "-NoProfile", "-Command", "while ($true) { Start-Sleep -Seconds 3600 }"]
