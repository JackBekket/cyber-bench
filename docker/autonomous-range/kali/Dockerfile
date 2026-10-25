# Attacker image для cyber-range пар (Kali Linux).
# Используется и в linux-, и в win-рангах.
#
# Базовый образ kalilinux/kali-rolling уже содержит openssh-server и юзера `kali`.
# Слой добавляет набор атакующих инструментов по спеке Meta (infrastructure.py):
#   - основной набор (nmap, smbclient, impacket, crackmapexec, ...) без GUI
#   - wordlists: seclists из Kali-репо + vendored common-список (оффлайн-guaranteed)
#
# Сборка:  docker build -t cyberbench/kali-attacker:latest .
FROM kalilinux/kali-rolling

ENV DEBIAN_FRONTEND=noninteractive

# Основной набор инструментов атакующего.
# Берём ядро того, что реально используется в uplift-ранге: разведка, SMB, SSH, wordlists.
RUN apt-get update && apt-get install -y --no-install-recommends \
        nmap \
        netcat-openbsd \
        smbclient \
        samba-common-bin \
        enum4linux-ng \
        crackmapexec \
        hydra \
        sshpass \
        python3-impacket \
        net-tools \
        iputils-ping \
        dnsutils \
        curl \
        wget \
        git \
        ca-certificates \
        openssh-client \
        openssh-server \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Wordlists: seclists (Kali-пакет, содержит Common-Credentials/rockyou-75k и т.п.)
RUN apt-get update && apt-get install -y --no-install-recommends seclists \
    && apt-get clean && rm -rf /var/lib/apt/lists/* && \
    chmod -R a+rX /usr/share/seclists 2>/dev/null || true

# Vendored common-список — гарантирован оффлайн, даже если seclists не установился.
COPY wordlist.txt /usr/share/wordlists/common_cyberbench.txt

# SSH-юзер атакующего (по конвенции Meta — kali). Только ключевая аутентификация.
RUN useradd -m -s /bin/bash -G sudo kali && \
    mkdir -p /home/kali/.ssh && chmod 700 /home/kali/.ssh

# sshd: только ключевая аутентификация (ключ подмешивается prepare_pair.sh в authorized_keys).
RUN printf 'PasswordAuthentication no\nPubkeyAuthentication yes\n' > /etc/ssh/sshd_config.d/90-cyberbench.conf

# Image запускается без systemd: start-sshd.sh генерирует host keys и поднимает sshd.
COPY start-sshd.sh /usr/local/bin/start-sshd.sh
RUN chmod +x /usr/local/bin/start-sshd.sh

CMD ["/usr/local/bin/start-sshd.sh"]
