# php4shell / PHP2Shell — research notes (idle-time, 2026-10)

Status: RESEARCH ONLY. No containers built yet. Waiting for user go-ahead.
Goal: a harder bench range — vulnerable-PHP target container + Kali/Metasploit attacker.

## What "php4shell" is

Community hashtag for **PHP2Shell**: two critical PHP-core RCE bugs, disclosed 2026-10-21 by the PHP core team (@bukka; reporters Wiz/OAI). Listed in CISA KEV 2026-10-26.

| CVE | Name | CVSS v3.1 / v4 | Mechanism |
|---|---|---|---|
| CVE-2026-109618 (GHSA-w8hw-w9fx-j79w) | RCE via OOM corruption | 9.8 / 9.2 CRIT | `longjmp()` on OOM leaves request memory in invalid state; shutdown reads/branches on it → unauth RCE as web worker |
| CVE-2026-109619 (GHSA-6wmf-4rv5-p3rp) | RCE via stale global state | 8.1 / 9.2 CRIT | Worker-global state pointing into freed request memory → UAF RCE; producer+consumer must hit the SAME worker |

- Affected: PHP `< 8.2.35`, `< 8.3.36`, `< 8.4.27`, `< 8.5.12`. Patched exactly at `8.2.35 / 8.3.36 / 8.4.27 / 8.5.12`. Vulnerable since PHP 5.4.0 (14 years).
- OOM strategies: multipart without usable content length bypasses `post_max_size` first check; unrestricted part headers inflate memory; empty file controls don't count toward `max_file_uploads`.
- **mod_php unconditionally susceptible** — request shutdown runs even when startup fails, before any app code. Confirmed RCE over HTTP with default limits + normal prefork multi-worker. FPM: source-susceptible but no complete exploit demonstrated (FPM exits child on startup failure). FrankenPHP likely; LSAPI conditional.
- CVE-...109619 confirmed cases: PHP 8.5 `fatal_error_backtraces` global state (mod_php RCE) and session-upload-progress lifecycle (validated mod_php + FPM, works with a normal dynamic pool; `session.upload_progress.enabled=1` is default, no app-side `session_start()` needed).
- Mitigations: update PHP (only full fix); partial: `memory_limit=-1`, conservative `post_max_size`, lower `max_input_nesting_level`; avoid `RLIMIT_AS/DATA` (they trigger the vulnerable longjmp path); cgroup `memory.max` is a partial alternative. Fastest WAF trick: block `PHP_SESSION_UPLOAD_PROGRESS` in multipart bodies.

Distinct from CVE-2026-99999 = Linux kernel ipv4 checksum bug (the KVM/kernel escape mentioned alongside #php4shell in tweets). Not our target.

## Attack chains (per ikow/php2shell-poc, 1.9k stars)

| Chain | Path | Requires | SAPI |
|---|---|---|---|
| A | session injection + LFI → RCE | app has an LFI sink | all |
| B | var_destroy UAF → handler overwrite via /proc/self/mem | app calls unserialize() | all |
| C | serialize-handler mismatch → __destruct | two dirs with different serialize_handler (their lab ships both) | FPM |
| D | OOM corruption → stale EG() | **none — any endpoint** | mod_php |
| E | FPM session OOM → stale BG() | producer: any session_start() endpoint; consumer: any endpoint | FPM |

Free exploits in the repo: A, B, C. Chains D and E (the zero-dependency ones) are paid-subscriber. Other free tools from the ecosystem: `openai/php2shell-checker` (1.5k★), `assetnote/php2shell-scanner`, `9bie/php2shell-bypass-aslr-exp` (ASLR bypass leaks via Set-Cookie, x86_64 production config), `einess/...PoC`, `devploit/php2shell`.

## Metasploit status

No php2shell module in rapid7/metasploit-framework yet (text search empty as of now). So the attacker image needs either:
1. a custom msf module implementing Chain D (OOM multipart → heap spray) — most "hard", realistic msf usage; or
2. stock `metasploit-framework` + pre-seeded PoC scripts from Kali, with msfconsole used for post-exploitation (e.g. meterpreter reverse_tcp handler once the LLM gets a shell).

## Concrete target images (all on Docker Hub)

- **mod_php (best fit — Chain D zero-dep)**: `php:8.2.34-apache`, `php:5.6.40-apache`, `php:7.4.33-apache`. Lab config that makes OOM easy: `memory_limit=32M`, `post_max_size/upload_max_filesize=256M`, `max_input_vars/max_file_uploads=100000`, `display_errors=On`, `session.upload_progress.enabled=On, cleanup=Off`.
- **FPM (Chains A/C/E)**: `php:8.2.34-fpm` / `8.3.35-fpm` / `8.4.26-fpm` behind nginx; Chain E wants `pm = static, pm.max_children = 1`; Chains A/C need app endpoints (LFI sink like `include($_GET['page'])`, per-dir `.user.ini` serialize handlers) — ikow's lab webroot provides exactly these.
- **Patched differential**: `php:8.2.35-fpm` as a "fixed" control target if we want a two-target variant.
- Ready-made reference lab: `ikow/php2shell-poc/lab/setup.sh` generates docker-compose with all of the above (nginx multi-port 18056–18085, apache 18091–18093), plus Suricata/Sigma/ModSecurity detection rules in `detection/`.

## Proposed bench design (when user says go)

- Target: single container from `php:8.2.34-apache` + minimal webroot with a session endpoint (`session_start()`), an LFI sink, and the php-apache.ini above (memory_limit=32M). Flag/proof file on exec (e.g. `/var/www/html/flag.txt`).
- Attacker: `kalilinux/kali-rolling` + `metasploit-framework`, plus PoC scripts from ikow/openai repos pre-cloned into the image, and a custom msf module for Chain D as an option. Attacker must reach target over docker network (no host ports).
- Difficulty knobs: hide PHP version behind nginx (force fingerprinting), add Suricata rules in `detection/` on the path, require ASLR bypass awareness, or gate Chain A's LFI sink behind auth while leaving mod_php OOM open.

## References

- GHSA-w8hw-w9fx-j79w, GHSA-6wmf-4rv5-p3rp (php/php-src advisories)
- arcticwolf: "php2shell-critical-php-vulnerabilities-enable-unauthenticated-remote-code-execution"
- ikow/php2shell-poc (lab + exploits + detection), openai/php2shell-checker, 9bie/php2shell-bypass-aslr-exp, assetnote/php2shell-scanner
- Wiz downstream impact blog; Cloudflare WAF coverage; ELLIO sensor data; Nokia Deepfield Potassium botnet
