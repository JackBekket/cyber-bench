# Attacker image для php2shell-ранга (Kali + Metasploit + PoC-скрипты).
# Наследует набор базового cyberbench/kali-attacker (nmap, wordlists, sshd) и добавляет:
#   - metasploit-framework (apt, Kali rolling) — msfconsole для post-exploitation;
#   - /opt/php2shell — снимок ikow/php2shell-poc (exploit/ + poc/ + scanner/, только stdlib-python).
#     Это вендореные free-эксплойты: Chain A (session inject + LFI, 100%) и OOM-триггеры Chain D.
#
# Сборка требует сети (apt + git clone):  docker build -t cyberbench/kali-attacker-php2shell:latest .
FROM kalilinux/kali-rolling

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        nmap \
        netcat-openbsd \
        enum4linux-ng \
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
    && rm -rf /var/lib/apt/lists/*

# Metasploit: основной пакет (msfconsole, msfvenom). Крупный слой (~1-2GB), кэшируется docker'ом.
RUN apt-get update && apt-get install -y --no-install-recommends metasploit-framework \
    && rm -rf /var/lib/apt/lists/*

# PoC-скрипты php2shell (ikow): free Chain A + OOM-trigger PoCs. Только stdlib, работают оффлайн.
RUN git clone --depth 1 https://github.com/ikow/php2shell-poc.git /opt/php2shell \
    && chmod -R a+rX /opt/php2shell

# SSH-юзер атакующего (по конвенции cyber-bench — kali). Только ключевая аутентификация.
RUN useradd -m -s /bin/bash -G sudo kali && \
    mkdir -p /home/kali/.ssh && chmod 700 /home/kali/.ssh

RUN printf 'PasswordAuthentication no\nPubkeyAuthentication yes\n' > /etc/ssh/sshd_config.d/90-cyberbench.conf

# entrypoint: sshd foreground (harness), msfdb — только по требованию, не блокирует старт.
COPY start-sshd.sh /usr/local/bin/start-sshd.sh
RUN chmod +x /usr/local/bin/start-sshd.sh

CMD ["/usr/local/bin/start-sshd.sh"]
