# 一键启动 WorldMonitor 本地栈（Redis + REST 代理 + API sidecar + 前端）
#
# 用法：在不受限的终端里运行（Windows 版 Redis 需要创建命名管道，受限沙箱会拒绝）
#   powershell -ExecutionPolicy Bypass -File .\start-stack.ps1
#   powershell -ExecutionPolicy Bypass -File .\start-stack.ps1 -SkipVite
#
# 依赖：.env\stack.env（密钥）、.env\redis\bin8（Redis 8）、.env\redis-rest（REST 代理）

param(
  [switch]$SkipVite
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here
$log = Join-Path $here 'logs'
New-Item -ItemType Directory -Force -Path $log | Out-Null

function Read-StackEnv {
  $cfg = @{}
  foreach ($line in Get-Content (Join-Path $here 'stack.env')) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $kv = $line -split '=', 2
    $cfg[$kv[0].Trim()] = $kv[1].Trim()
  }
  return $cfg
}

function Test-Port([int]$port) {
  $null -ne (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Wait-Port([int]$port, [int]$seconds = 30) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-Port $port) { return $true }
    Start-Sleep -Milliseconds 500
  }
  return $false
}

$cfg = Read-StackEnv

# ---------- 1. Redis ----------
if (Test-Port 6379) {
  Write-Host '[redis]  已在 6379 运行，跳过'
} else {
  $redisExe = (Get-ChildItem (Join-Path $here 'redis\bin8') -Recurse -Filter 'redis-server.exe' | Select-Object -First 1).FullName
  if (-not $redisExe) { throw "找不到 redis-server.exe，请检查 .env\redis\bin8" }
  Write-Host '[redis]  启动中…'
  Start-Process -FilePath $redisExe -WindowStyle Hidden `
    -ArgumentList @('--port', '6379', '--bind', '127.0.0.1',
      '--requirepass', $cfg.REDIS_PASSWORD,
      '--dir', (Join-Path $here 'redis\data'),
      '--appendonly', 'yes',
      '--appendfsync', 'everysec',
      '--save', '900', '1') `
    -RedirectStandardOutput (Join-Path $log 'redis.out.log') `
    -RedirectStandardError  (Join-Path $log 'redis.err.log')
  if (-not (Wait-Port 6379)) { throw 'Redis 未能在 30s 内监听 6379' }
  Write-Host '[redis]  OK'
}

# ---------- 2. Redis REST 代理 ----------
if (Test-Port 8079) {
  Write-Host '[redis-rest] 已在 8079 运行，跳过'
} else {
  Write-Host '[redis-rest] 启动中…'
  $env:SRH_TOKEN   = $cfg.REDIS_TOKEN
  $env:REDIS_URL   = "redis://:$($cfg.REDIS_PASSWORD)@127.0.0.1:6379"
  $env:PORT        = '8079'
  Start-Process -FilePath 'node' -WindowStyle Hidden `
    -ArgumentList (Join-Path $here 'redis-rest\redis-rest-proxy.mjs') `
    -WorkingDirectory (Join-Path $here 'redis-rest') `
    -RedirectStandardOutput (Join-Path $log 'redis-rest.out.log') `
    -RedirectStandardError  (Join-Path $log 'redis-rest.err.log')
  if (-not (Wait-Port 8079)) { throw 'REST 代理未能在 30s 内监听 8079' }
  Write-Host '[redis-rest] OK'
}

# ---------- 3. 翻译网关（OpenAI 兼容，供 ollama 提供方使用） ----------
$mtPort = if ($cfg.MT_PORT) { [int]$cfg.MT_PORT } else { 11434 }
if (Test-Port $mtPort) {
  Write-Host "[mt]     已在 $mtPort 运行，跳过"
} else {
  Write-Host '[mt]     启动中…'
  $env:MT_PROVIDER = $cfg.MT_PROVIDER
  $env:MT_PORT     = "$mtPort"
  if ($cfg.MT_BASE)  { $env:MT_BASE  = $cfg.MT_BASE }
  if ($cfg.MT_KEY)   { $env:MT_KEY   = $cfg.MT_KEY }
  if ($cfg.MT_MODEL) { $env:MT_MODEL = $cfg.MT_MODEL }
  Start-Process -FilePath 'node' -WindowStyle Hidden `
    -ArgumentList (Join-Path $here 'mt-gateway.mjs') `
    -WorkingDirectory $here `
    -RedirectStandardOutput (Join-Path $log 'mt.out.log') `
    -RedirectStandardError  (Join-Path $log 'mt.err.log')
  if (-not (Wait-Port $mtPort 30)) { throw "翻译网关未能在 30s 内监听 $mtPort" }
  Write-Host "[mt]     OK ($($cfg.MT_PROVIDER))"
}

# ---------- 4. API sidecar ----------
if (Test-Port ([int]$cfg.LOCAL_API_PORT)) {
  Write-Host "[api]    已在 $($cfg.LOCAL_API_PORT) 运行，跳过"
} else {
  Write-Host '[api]    启动中…'
  $env:UPSTASH_REDIS_REST_URL        = $cfg.UPSTASH_REDIS_REST_URL
  $env:UPSTASH_REDIS_REST_TOKEN      = $cfg.REDIS_TOKEN
  $env:UPSTASH_ALLOW_INSECURE_HTTP   = 'true'
  $env:WM_SESSION_SECRET             = $cfg.WM_SESSION_SECRET
  $env:LOCAL_API_MODE                = $cfg.LOCAL_API_MODE
  $env:LOCAL_API_PORT                = $cfg.LOCAL_API_PORT
  $env:LOCAL_API_TOKEN               = $cfg.LOCAL_API_TOKEN
  $env:LOCAL_API_RESOURCE_DIR        = $repo
  # 翻译/摘要走本地网关（ollama 提供方）。isLocalDeployment() 会跳过 hostname 白名单。
  $env:OLLAMA_API_URL                = $cfg.OLLAMA_API_URL
  $env:OLLAMA_MODEL                  = $cfg.OLLAMA_MODEL
  $env:OLLAMA_API_KEY                = $cfg.OLLAMA_API_KEY
  Start-Process -FilePath 'node' -WindowStyle Hidden `
    -ArgumentList (Join-Path $repo 'src-tauri\sidecar\local-api-server.mjs') `
    -WorkingDirectory $repo `
    -RedirectStandardOutput (Join-Path $log 'sidecar.out.log') `
    -RedirectStandardError  (Join-Path $log 'sidecar.err.log')
  if (-not (Wait-Port ([int]$cfg.LOCAL_API_PORT) 60)) { throw 'API sidecar 未能在 60s 内就绪' }
  Write-Host '[api]    OK'
}

# ---------- 4. 前端（vite） ----------
if ($SkipVite) {
  Write-Host '[vite]   已跳过'
} else {
  if (Test-Port 3000) {
    Write-Host '[vite]   已在 3000 运行，跳过'
  } else {
    Write-Host '[vite]   启动中…（首次编译约 10s）'
    $env:LOCAL_API_TOKEN = $cfg.LOCAL_API_TOKEN
    $env:LOCAL_API_PORT  = $cfg.LOCAL_API_PORT
    Start-Process -FilePath 'npm.cmd' -WindowStyle Hidden -ArgumentList 'run', 'dev' `
      -WorkingDirectory $repo `
      -RedirectStandardOutput (Join-Path $log 'vite.out.log') `
      -RedirectStandardError  (Join-Path $log 'vite.err.log')
    if (-not (Wait-Port 3000 90)) { throw 'vite 未能在 90s 内监听 3000' }
    Write-Host '[vite]   OK'
  }
}

# ---------- 5. 自检 ----------
Write-Host ''
Write-Host '--- 自检 ---'
try {
  $mint = Invoke-RestMethod -Method Post -Uri 'http://localhost:3000/api/wm-session' -TimeoutSec 15
  Write-Host "会话铸造: 200 (token $($mint.token.Substring(0,12))…)"
  $boot = Invoke-RestMethod -Uri 'http://localhost:3000/api/bootstrap' -TimeoutSec 30 `
    -Headers @{ 'X-WorldMonitor-Key' = $mint.token }
  $have = 0
  if ($boot.data) { $have = @($boot.data.PSObject.Properties).Count }
  $miss = 0
  if ($boot.missing) { $miss = @($boot.missing).Count }
  Write-Host "bootstrap: OK，已有 $have 个数据集，缺 $miss 个"
} catch {
  Write-Warning "自检失败: $($_.Exception.Message)"
}

Write-Host ''
Write-Host '打开 http://localhost:3000/'
Write-Host "日志目录: $log"
Write-Host '停止全部: .\stop-stack.ps1'
