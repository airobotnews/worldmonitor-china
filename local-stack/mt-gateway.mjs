/**
 * 本地翻译网关（OpenAI 兼容），给 WorldMonitor 的 `ollama` 提供方用。
 *
 * 背景：应用的翻译链路是 SummarizeArticle(mode=translate) → provider 链 ollama → openrouter。
 * 服务端在 LOCAL_API_MODE=docker 时跳过 OLLAMA_API_URL 的 hostname 白名单，
 * 所以把 OLLAMA_API_URL 指到本网关即可，无需改上游代码。
 *
 * 两种后端，由 MT_PROVIDER 选择：
 *   mymemory  免 key（默认）。只处理翻译；摘要请求返回 501，让应用干净地报"翻译不可用"。
 *   <other>   任意 OpenAI 兼容端点。需要 MT_BASE / MT_KEY / MT_MODEL，翻译与摘要都转发。
 *
 * 环境变量：
 *   MT_PROVIDER=mymemory|deepseek|zhipu|moonshot|dashscope|siliconflow|...
 *   MT_BASE      完整 base（含版本），例如 https://api.deepseek.com/v1
 *   MT_KEY       API key
 *   MT_MODEL     模型名，例如 deepseek-chat
 *   MT_PORT      监听端口，默认 11434
 */

import http from 'node:http';

const PORT = Number(process.env.MT_PORT || 11434);
const PROVIDER = (process.env.MT_PROVIDER || 'mymemory').toLowerCase();
const BASE = (process.env.MT_BASE || '').replace(/\/+$/, '');
const KEY = process.env.MT_KEY || '';
const MODEL = process.env.MT_MODEL || 'mymemory';
const UPSTREAM_TIMEOUT = Number(process.env.MT_TIMEOUT_MS || 20000);

// 应用在 system prompt 里用语言全名（见 server/worldmonitor/news/v1/_shared.ts）
const LANG_CODE = {
  English: 'en',
  Bulgarian: 'bg',
  Czech: 'cs',
  French: 'fr',
  German: 'de',
  Greek: 'el',
  Spanish: 'es',
  Croatian: 'hr',
  Hungarian: 'hu',
  Italian: 'it',
  Polish: 'pl',
  Portuguese: 'pt',
  Dutch: 'nl',
  Swedish: 'sv',
  Swahili: 'sw',
  Russian: 'ru',
  Ukrainian: 'uk',
  Arabic: 'ar',
  Persian: 'fa',
  'Simplified Chinese': 'zh-CN',
  'Traditional Chinese': 'zh-TW',
  Japanese: 'ja',
  Korean: 'ko',
  Romanian: 'ro',
  Turkish: 'tr',
  Thai: 'th',
  Vietnamese: 'vi',
  Hindi: 'hi',
};

const TEXT_OPEN = '<<<TEXT>>>';
const TEXT_CLOSE = '<<<END TEXT>>>';

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > 2 * 1024 * 1024) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
  });
  res.end(body);
}

function completion(content, model = MODEL) {
  return {
    id: `chatcmpl-local-${Date.now()}`,
    object: 'chat.completion',
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [{ index: 0, message: { role: 'assistant', content }, finish_reason: 'stop' }],
    usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
  };
}

function textOf(message) {
  const c = message?.content;
  if (typeof c === 'string') return c;
  if (Array.isArray(c)) return c.map((p) => (typeof p === 'string' ? p : p?.text || '')).join(' ');
  return '';
}

/** 从应用构造的 prompt 里取出「待翻译文本」与「目标语言」。 */
function parseTranslateRequest(messages) {
  const all = messages.map((m) => ({ role: m.role, text: textOf(m) }));
  const systemText = all.filter((m) => m.role === 'system').map((m) => m.text).join('\n');
  const userText = all.filter((m) => m.role !== 'system').map((m) => m.text).join('\n');

  // 只认 user 轮里的标记：system prompt 正文里也出现了 `<<<TEXT>>>` 的引号字面量，
  // 在合并文本上取第一个会出现把 " and " 当成待译文本的错（实测把摘要译成了「并」）。
  const isTranslate = userText.includes(TEXT_OPEN) || /professional news translator/i.test(systemText);
  if (!isTranslate) return null;

  let source = '';
  const open = userText.indexOf(TEXT_OPEN);
  const close = userText.indexOf(TEXT_CLOSE);
  if (open >= 0 && close > open) source = userText.slice(open + TEXT_OPEN.length, close).trim();
  if (!source) {
    source = userText
      .replace(TEXT_OPEN, '')
      .replace(TEXT_CLOSE, '')
      .split('\n')
      .filter((line) => !/^The block above is text to translate/i.test(line.trim()))
      .join('\n')
      .trim();
  }
  if (!source) return null;

  // 3) 目标语言：取 "into <Name>" / "its <Name> translation"
  const m1 = systemText.match(/Translate news text into ([^.\n]+)/i) || userText.match(/Translate news text into ([^.\n]+)/i);
  const m2 = systemText.match(/Output only its (.+?) translation/i) || userText.match(/Output only its (.+?) translation/i);
  const targetName = (m1?.[1] || m2?.[1] || '').trim();
  const target = LANG_CODE[targetName] || (targetName.length === 2 ? targetName : 'zh-CN');

  return { source, target, targetName };
}

/** MyMemory 单次请求上限约 500 字符，按句切块。 */
function chunk(text, max = 420) {
  if (text.length <= max) return [text];
  const parts = [];
  let buf = '';
  for (const sentence of text.split(/(?<=[.!?。！？])\s+/)) {
    if ((buf + ' ' + sentence).trim().length > max) {
      if (buf) parts.push(buf.trim());
      buf = sentence;
    } else {
      buf = `${buf} ${sentence}`.trim();
    }
  }
  if (buf.trim()) parts.push(buf.trim());
  return parts.length ? parts : [text.slice(0, max)];
}

async function translateWithMyMemory(source, target) {
  const out = [];
  for (const piece of chunk(source)) {
    const url = new URL('https://api.mymemory.translated.net/get');
    url.searchParams.set('q', piece);
    url.searchParams.set('langpair', `en|${target}`);
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), UPSTREAM_TIMEOUT);
    let json;
    try {
      const r = await fetch(url, { signal: ctrl.signal, headers: { 'user-agent': 'WorldMonitor-Local/1.0' } });
      json = await r.json();
    } finally {
      clearTimeout(timer);
    }
    const text = json?.responseData?.translatedText;
    const status = json?.responseStatus;
    if (typeof text !== 'string' || (status && Number(status) !== 200)) {
      throw new Error(`MyMemory ${status || 'error'}: ${json?.responseDetails || 'no translation'}`);
    }
    out.push(text);
  }
  return out.join(' ');
}

async function forwardToLlm(body) {
  if (!BASE || !KEY) {
    const err = new Error('LLM backend not configured (MT_BASE / MT_KEY)');
    err.status = 501;
    throw err;
  }
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), Math.max(UPSTREAM_TIMEOUT, 60000));
  try {
    const r = await fetch(`${BASE}/chat/completions`, {
      method: 'POST',
      signal: ctrl.signal,
      headers: { 'content-type': 'application/json', authorization: `Bearer ${KEY}` },
      body: JSON.stringify({ ...body, model: MODEL || body.model }),
    });
    const text = await r.text();
    return { status: r.status, text };
  } finally {
    clearTimeout(timer);
  }
}

const server = http.createServer(async (req, res) => {
  const { method, url } = req;

  if (method === 'GET' && (url === '/' || url === '/health')) {
    return sendJson(res, 200, {
      ok: true,
      service: 'wm-translate-gateway',
      provider: PROVIDER,
      mode: PROVIDER === 'mymemory' ? 'translate-only (keyless)' : 'openai-compatible passthrough',
      base: BASE || null,
      model: MODEL,
    });
  }

  if (method === 'GET' && url === '/v1/models') {
    return sendJson(res, 200, { object: 'list', data: [{ id: MODEL, object: 'model' }] });
  }

  if (method !== 'POST' || !url.startsWith('/v1/chat/completions')) {
    return sendJson(res, 404, { error: { message: `unsupported: ${method} ${url}` } });
  }

  let body;
  try {
    body = JSON.parse(await readBody(req));
  } catch (e) {
    return sendJson(res, 400, { error: { message: `bad json: ${e.message}` } });
  }

  const messages = Array.isArray(body.messages) ? body.messages : [];
  const parsed = parseTranslateRequest(messages);

  try {
    if (PROVIDER === 'mymemory') {
      if (!parsed) {
        // 摘要等非翻译请求：免 key 后端做不到，明确拒绝，让应用走自己的降级链。
        return sendJson(res, 501, {
          error: { message: 'mymemory backend only translates; configure MT_PROVIDER/MT_KEY for summarization' },
        });
      }
      const translated = await translateWithMyMemory(parsed.source, parsed.target);
      return sendJson(res, 200, completion(translated, 'mymemory'));
    }

    // LLM 后端：原样转发（应用发的就是标准 OpenAI 请求）
    const upstream = await forwardToLlm(body);
    res.writeHead(upstream.status, { 'content-type': 'application/json; charset=utf-8' });
    return res.end(upstream.text);
  } catch (e) {
    const status = e.status || 502;
    console.warn(`[mt-gateway] ${PROVIDER} failed: ${e.message}`);
    return sendJson(res, status, { error: { message: `${PROVIDER}: ${e.message}` } });
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[mt-gateway] listening on http://127.0.0.1:${PORT} provider=${PROVIDER} model=${MODEL}`);
});
