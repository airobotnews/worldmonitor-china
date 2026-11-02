# 停止 WorldMonitor 本地栈（vite / API sidecar / REST 代理 / Redis）
#
# 用法：powershell -ExecutionPolicy Bypass -File .\stop-stack.ps1

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# 停之前先让 Redis 落盘：AOF 已经做到秒级持久化，但显式 SAVE 能保证
# 最后一次 RDB 快照也落盘（重启时 AOF 优先重放，双保险）。
if (Get-NetTCPConnection -State Listen -LocalPort 6379 -ErrorAction SilentlyContinue) {
  $cfg = @{}
  foreach ($line in Get-Content (Join-Path $here 'stack.env')) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $kv = $line -split '=', 2
    $cfg[$kv[0].Trim()] = $kv[1].Trim()
  }
  $cli = (Get-ChildItem (Join-Path $here 'redis\bin8') -Recurse -Filter 'redis-cli.exe' | Select-Object -First 1).FullName
  if ($cli -and $cfg.REDIS_PASSWORD) {
    & $cli -h 127.0.0.1 -p 6379 -a $cfg.REDIS_PASSWORD --no-auth-warning SAVE 2>$null | Out-Null
    Write-Host '[redis] 已执行 SAVE'
  }
}

$ports = @(
  @{ Port = 3000;  Name = 'vite' },
  @{ Port = 46123; Name = 'api-sidecar' },
  @{ Port = 11434; Name = 'mt-gateway' },
  @{ Port = 8079;  Name = 'redis-rest' },
  @{ Port = 6379;  Name = 'redis' }
)

foreach ($entry in $ports) {
  $conns = Get-NetTCPConnection -State Listen -LocalPort $entry.Port -ErrorAction SilentlyContinue
  if (-not $conns) {
    Write-Host ("[{0}] 端口 {1} 未监听，跳过" -f $entry.Name, $entry.Port)
    continue
  }
  foreach ($pid_ in ($conns.OwningProcess | Sort-Object -Unique)) {
    try {
      Stop-Process -Id $pid_ -Force -ErrorAction Stop
      Write-Host ("[{0}] 已停止 PID {1}" -f $entry.Name, $pid_)
    } catch {
      Write-Warning ("[{0}] 无法停止 PID {1}: {2}" -f $entry.Name, $pid_, $_.Exception.Message)
    }
  }
}

Start-Sleep -Seconds 2
Write-Host ''
Write-Host '剩余监听：'
$left = 3000, 46123, 8079, 6379 | Where-Object { Get-NetTCPConnection -State Listen -LocalPort $_ -ErrorAction SilentlyContinue }
if ($left) { Write-Host ("  " + ($left -join ', ')) } else { Write-Host '  无（已全部停止）' }

Write-Host ''
Write-Host 'Redis 数据仍保存在 .env\redis\data，下次启动会自动加载。'
