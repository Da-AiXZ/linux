# 本机后台服务（日志回传 + 实验观察）
#
# 用法：右键"使用 PowerShell 运行"，或
#   powershell -ExecutionPolicy Bypass -File Tools\start_services.ps1
#
# 两个进程都是普通控制台窗口（最小化），关掉窗口即停止：
#   log_server.py      监听 0.0.0.0:8765，收日志、发命令
#   watch_experiment.py 等两批自检跑完，把判定写进 .remote\verdict.txt

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# 别让 WorkBuddy 的代理环境影响本机服务
Remove-Item Env:HTTP_PROXY -ErrorAction SilentlyContinue
Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue
Remove-Item Env:ALL_PROXY -ErrorAction SilentlyContinue

$python = (Get-Command python).Source
if (-not $python) { $python = (Get-Command py).Source }

Start-Process -FilePath $python `
  -ArgumentList "`"$root\Tools\log_server.py`"" `
  -WorkingDirectory $root -WindowStyle Minimized

Start-Sleep -Seconds 2

Start-Process -FilePath $python `
  -ArgumentList "`"$root\Tools\watch_experiment.py`"","--build","0.41.0","--expect","2","--timeout","3600" `
  -WorkingDirectory $root -WindowStyle Minimized

Write-Host "started: log_server.py (8765) + watch_experiment.py"
Write-Host "verdict: $root\.remote\verdict.txt"
