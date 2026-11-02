# 本地一键启动（Windows）

这套脚本把 WorldMonitor 的完整自托管栈跑在本机，不需要 Docker：

```
浏览器 ──> vite :3000 ──┬─> sebuf RPC 处理器（进程内）
                        └─> /api/* ──> API sidecar :46123 ──> Redis :6379
                                                   └─> 翻译网关 :11434
```

容器方案里 nginx 负责「静态文件 + 反向代理 /api 并注入内网令牌」，这里由 vite 的
`server.proxy` 承担同样的角色（见仓库根 `vite.config.ts` 里的 `[china-fork]` 段）。

## 一、前置

| 项 | 要求 | 说明 |
|---|---|---|
| Node.js | **24**（`nvm install` 会读 `.nvmrc`） | 低版本会在 `npm ci` 阶段报错 |
| Redis | **7.0 以上** | 必须。限流的降级路径用到 `EXPIRE ... NX`，Redis 5 会直接报错 |
| 操作系统 | Windows 10/11 + PowerShell 5.1 | 脚本用 `Start-Process` 拉子进程 |

Redis 用便携版即可（免安装）：把 `redis-server.exe` 所在目录放到 `local-stack/redis/bin8/`。
建议取 7.x/8.x 的 Windows 构建（msys2 版），目录结构：

```
local-stack/
  redis/bin8/redis-server.exe
  redis/data/                 # AOF/RDB 落盘位置，自动创建
  redis-rest/                 # Upstash 兼容 REST 代理（见下）
```

## 二、准备 REST 代理

API sidecar 只认 Upstash 的 REST 协议，所以需要一个本地代理把 REST 翻成 RESP：

```powershell
mkdir local-stack\redis-rest
cd local-stack\redis-rest
npm init -y
npm install redis@4
# 复用仓库里现成的实现
copy ..\..\docker\redis-rest-proxy.mjs .
```

## 三、密钥

```powershell
copy local-stack\stack.env.example local-stack\stack.env
# 然后编辑 stack.env，把 4 个 <64 位 hex> 换成随机值：
-join ((1..64) | ForEach-Object { '{0:x}' -f (Get-Random -Max 16) })
```

`stack.env` 已在 `local-stack/.gitignore` 里，不会进仓库。

## 四、安装前端依赖

```powershell
npm ci --ignore-scripts --registry https://registry.npmmirror.com
node scripts/generate-inventory-facts.mjs   # 补被 --ignore-scripts 跳过的派生文件
```

> 国内网络注意：`npm ci` 可能因 TLS 被中间盒打断而留下**半截包**，症状是
> `rollup ... is not a valid Win32 application`。删掉 `node_modules` 重跑 `npm ci`
> 即可（锁文件会强制校验每个 tarball 的完整性）。

## 五、启动 / 停止

```powershell
.\local-stack\start-worldmonitor.cmd    # 起全栈 + 开浏览器
.\local-stack\stop-worldmonitor.cmd     # 停全栈（停之前先让 Redis 落盘）
```

脚本是幂等的：每个服务启动前先探端口，已在跑的跳过，所以重复双击只会再开一次浏览器。

**必须用普通控制台运行**（双击即可）。如果你在受限沙箱里跑会看到：

- Windows 版 Redis 报 `couldn't create signal pipe, Win32 error 5`
- vite 报 `spawn EPERM`（esbuild 需要命名管道）

两者都是沙箱禁止命名管道导致的，不是脚本问题。

## 六、翻译与摘要

`mt-gateway.mjs` 是一个 OpenAI 兼容网关，伪装成 `ollama` 提供方被应用调用
（应用的服务端在 `LOCAL_API_MODE=docker` 时会跳过该地址的主机白名单）。

| `MT_PROVIDER` | 能力 | 是否要 key |
|---|---|---|
| `mymemory` | **只翻译**，摘要请求返回 501 | 否 |
| `zhipu` / `deepseek` / `moonshot` / `dashscope` / `siliconflow` | 翻译 + 摘要 | 是 |

换后端只改 `stack.env` 的 `MT_*` 四项，重启即可。`MT_BASE` 要带版本号，网关会拼
`/chat/completions`。

## 七、种子数据（可选）

新闻面板是实时抓取的（每 10 分钟），不依赖 Redis。但地震、天气预警、网络威胁、
CII、预测市场这些面板读的是**种子脚本**写进 Redis 的快照：

```powershell
$env:UPSTASH_REDIS_REST_URL='http://127.0.0.1:8079'
$env:UPSTASH_REDIS_REST_TOKEN=(从 stack.env 取 REDIS_TOKEN)
$env:UPSTASH_ALLOW_INSECURE_HTTP='true'

node scripts/seed-earthquakes.mjs
node scripts/seed-natural-events.mjs
node scripts/seed-weather-alerts.mjs
node scripts/seed-cyber-threats.mjs
```

新鲜度预算（`api/health.js`）：地震 30 分钟、天气 45 分钟、网络威胁 240 分钟。
过期不会伪装成最新，但也不会自动刷新——需要自己跑或挂计划任务。

## 八、故障排查

| 现象 | 原因 | 处置 |
|---|---|---|
| `/api/bootstrap` 返回 JS 源码 | vite 没配 `/api` 代理（`LOCAL_API_TOKEN`/`LOCAL_API_PORT` 未导出） | 用 `start-worldmonitor.cmd` 启动，别直接 `npm run dev` |
| 面板显示「数据不足」 | 种子没跑或已过期 | 见第七节 |
| 面板显示「最近 1 小时内没有条目」 | 时间窗太窄 + RSS 条目多是几小时前 | 切 24h / 7d |
| 面板数比预期少 | free 档上限裁剪（自托管无权益后端） | 本仓库已把上限提到 200，见 `src/config/panels.ts` |
| 地图空白 | 瓦片源不可达 | 设 `VITE_PMTILES_URL` 走自托管 PMTiles |

日志在 `local-stack/logs/`（redis / redis-rest / sidecar / mt / vite 各一组）。
