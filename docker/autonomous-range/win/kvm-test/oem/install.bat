@echo off
rem Cyberbench smoke-test: проверяем PowerShell и пишем маркер.
powershell -NoProfile -Command "$os=(Get-CimInstance Win32_OperatingSystem).Caption; $ps=$PSVersionTable.PSVersion.ToString(); Set-Content C:\OEM\smoke.txt ('OS=' + $os + \"`nPS=\" + $ps + \"`nwhoami=\" + (whoami))"
echo SMOKE_DONE >> C:\OEM\smoke.txt
