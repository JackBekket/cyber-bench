#!/usr/bin/env python3
"""Генерит patches/purplellama.ssh-read-deadline.patch поверх submodule HEAD."""
import subprocess, sys, pathlib

PL = pathlib.Path(__file__).resolve().parent.parent / "PurpleLlama"
ssh = PL / "CybersecurityBenchmarks/benchmark/ssh.py"
orig = ssh.read_text()

OLD_IMPORTS = """import logging
from io import StringIO
from typing import Any, Dict, List, Optional

import paramiko
"""
NEW_IMPORTS = """import logging
from concurrent.futures import TimeoutError as FutureTimeoutError
from concurrent.futures import ThreadPoolExecutor
from functools import partial
from io import StringIO
from time import monotonic
from typing import Any, Callable, Dict, List, Optional

import paramiko
"""

OLD_BODY = """            try:
                stdout = _stdout.read(self.max_stdout_read_bytes).decode()
            except UnicodeDecodeError:
                stdout = "[!] The command produced non-unicode output on stdout."

            try:
                stderr = _stderr.read(self.max_stderr_read_bytes).decode()
            except UnicodeDecodeError:
                stderr = "[!] The command produced non-unicode output on stderr."
        except TimeoutError:
            stdout = ""
            stderr = "[!] The command timed out."
"""
NEW_BODY = """            deadline = (
                monotonic() + self.command_timeout if self.command_timeout else None
            )

            def _read_with_deadline(reader, size: int) -> bytes:
                pool = ThreadPoolExecutor(max_workers=1)
                try:
                    fut = pool.submit(partial(reader.read, size))
                    remaining = (deadline - monotonic()) if deadline is not None else None
                    return fut.result(timeout=remaining)
                except FutureTimeoutError:
                    raise TimeoutError(
                        "SSH command read exceeded the wall-clock deadline"
                    )
                finally:
                    # wait=False: воркер может всё ещё висеть в reader.read;
                    # после close() канала он получит EOF и завершится сам.
                    pool.shutdown(wait=False)

            def _abort_channel(channel) -> None:
                try:
                    channel.close()  # закрывает exec-канал => sshd убивает команду
                except Exception:
                    pass

            timed_out = False
            try:
                stdout = _read_with_deadline(_stdout, self.max_stdout_read_bytes).decode()
            except UnicodeDecodeError:
                stdout = "[!] The command produced non-unicode output on stdout."
            except TimeoutError:
                stdout = ""
                timed_out = True
                _abort_channel(getattr(_stdout, "channel", None))

            try:
                stderr = _read_with_deadline(_stderr, self.max_stderr_read_bytes).decode()
            except UnicodeDecodeError:
                stderr = "[!] The command produced non-unicode output on stderr."
            except TimeoutError:
                timed_out = True
                _abort_channel(getattr(_stderr, "channel", None))

            if timed_out and not stderr:
                stderr = (
                    "[!] The command timed out before finishing; "
                    "run a shorter command or cap its runtime, e.g. `timeout 60 <cmd>`."
                )
        except TimeoutError:
            stdout = ""
            stderr = "[!] The command timed out."
"""

for old, new in ((OLD_IMPORTS, NEW_IMPORTS), (OLD_BODY, NEW_BODY)):
    if orig.count(old) != 1:
        sys.exit(f"ERROR: block found {orig.count(old)} times:\n{old[:80]}...")
    orig = orig.replace(old, new)

ssh.write_text(orig)
diff = subprocess.run(
    ["git", "diff", "--no-color"], cwd=PL, capture_output=True, text=True, check=True
).stdout
out = pathlib.Path(__file__).resolve().parent / "purplellama.ssh-read-deadline.patch"
out.write_text(diff)
print(f"wrote {out} ({len(diff)} bytes)")
