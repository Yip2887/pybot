/*
 * TL;DR Crawler - background.js (MV3 service worker)
 * Toolbar toggle + the only place that talks to the Anthropic API.
 */
'use strict';

const API_URL = 'https://api.anthropic.com/v1/messages';
const DEFAULT_MODEL = 'claude-3-5-haiku-latest';
const TIMEOUT_MS = 30000;
const MAX_TOKENS = 1024;
const MAX_BATCH = 20; // sentences per request

chrome.action.onClicked.addListener((tab) => {
  if (!tab || tab.id == null) return;
  // content.js self-toggles: re-injecting stops the running crawler.
  chrome.scripting
    .executeScript({ target: { tabId: tab.id }, files: ['core.js', 'content.js'] })
    .catch((err) => {
      console.warn('[TL;DR Crawler] cannot run on this page:', err && err.message);
      chrome.action.setBadgeText({ tabId: tab.id, text: '—' });
      chrome.action.setBadgeBackgroundColor({ tabId: tab.id, color: '#ff7ab8' });
      setTimeout(() => chrome.action.setBadgeText({ tabId: tab.id, text: '' }).catch(() => {}), 2000);
    });
});

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (!msg || typeof msg !== 'object') return;

  if (msg.type === 'tldr:config') {
    getConfig()
      .then((c) => sendResponse({ ok: true, hasKey: !!c.apiKey, model: c.model }))
      .catch(() => sendResponse({ ok: false, error: 'config' }));
    return true;
  }
  if (msg.type === 'tldr:summarize') {
    summarize(msg.sentences).then(sendResponse).catch(() => sendResponse({ ok: false, error: 'unknown' }));
    return true;
  }
  if (msg.type === 'tldr:final') {
    finalSummary(msg.sentences).then(sendResponse).catch(() => sendResponse({ ok: false, error: 'unknown' }));
    return true;
  }
  return undefined;
});

async function getConfig() {
  const d = await chrome.storage.local.get(['apiKey', 'model']);
  const apiKey = typeof d.apiKey === 'string' ? d.apiKey.trim() : '';
  const model = typeof d.model === 'string' && d.model.trim() ? d.model.trim() : DEFAULT_MODEL;
  return { apiKey, model };
}

// Returns {ok:true, text} or {ok:false, error}. Never throws.
async function callClaude(prompt, maxTokens) {
  let cfg;
  try { cfg = await getConfig(); } catch (e) { return { ok: false, error: 'config' }; }
  if (!cfg.apiKey) return { ok: false, error: 'no-key' };

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(API_URL, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-api-key': cfg.apiKey,
        'anthropic-version': '2023-06-01',
        // required for direct browser/extension calls to the Messages API
        'anthropic-dangerous-direct-browser-access': 'true'
      },
      body: JSON.stringify({
        model: cfg.model,
        max_tokens: maxTokens,
        messages: [{ role: 'user', content: prompt }]
      }),
      signal: ctrl.signal
    });

    if (!res.ok) {
      let detail = '';
      try { detail = (await res.text()).slice(0, 300); } catch (e) { /* ignore */ }
      return { ok: false, error: 'http-' + res.status, detail };
    }
    const data = await res.json();
    const text = (data && Array.isArray(data.content) ? data.content : [])
      .filter((b) => b && b.type === 'text' && typeof b.text === 'string')
      .map((b) => b.text)
      .join('\n')
      .trim();
    if (!text) return { ok: false, error: 'empty' };
    return { ok: true, text };
  } catch (e) {
    return { ok: false, error: e && e.name === 'AbortError' ? 'timeout' : 'network' };
  } finally {
    clearTimeout(timer);
  }
}

function parseJsonArray(text) {
  const a = text.indexOf('[');
  const b = text.lastIndexOf(']');
  if (a < 0 || b <= a) return null;
  try {
    const v = JSON.parse(text.slice(a, b + 1));
    return Array.isArray(v) ? v : null;
  } catch (e) {
    return null;
  }
}

async function summarize(sentences) {
  const list = (Array.isArray(sentences) ? sentences : [])
    .filter((s) => typeof s === 'string' && s.trim())
    .slice(0, MAX_BATCH);
  if (!list.length) return { ok: false, error: 'empty' };

  const prompt = [
    'Compress each sentence below into an extremely short TL;DR fragment.',
    'Rules:',
    '- Reply with ONLY a JSON array of strings, one per input sentence, in the same order.',
    '- Each fragment: at most 9 words.',
    '- Keep every number, percentage, currency value and date EXACTLY as written.',
    '- Keep person names, company names and product names.',
    '- Never add facts that are not in that sentence. Never exaggerate.',
    '- Be direct and concrete. No quotes, no filler.',
    '',
    'Input sentences:',
    JSON.stringify(list)
  ].join('\n');

  const r = await callClaude(prompt, MAX_TOKENS);
  if (!r.ok) return r;
  const arr = parseJsonArray(r.text);
  if (!arr) return { ok: false, error: 'parse' };
  return {
    ok: true,
    summaries: arr.map((x) =>
      typeof x === 'string' ? x : x && typeof x.summary === 'string' ? x.summary : ''
    )
  };
}

async function finalSummary(sentences) {
  const list = (Array.isArray(sentences) ? sentences : [])
    .filter((s) => typeof s === 'string' && s.trim())
    .slice(0, 80);
  if (!list.length) return { ok: false, error: 'empty' };

  const prompt = [
    'Write a TL;DR of the article excerpts below.',
    'Rules:',
    '- Reply with ONLY a JSON array of exactly 3 short strings.',
    '- Each string is one short sentence: what happened, the key numbers, the impact.',
    '- Use ONLY facts present in the input. Add no new facts. Do not exaggerate.',
    '- Every number must be copied exactly as written.',
    '',
    'Article excerpts:',
    JSON.stringify(list)
  ].join('\n');

  const r = await callClaude(prompt, MAX_TOKENS);
  if (!r.ok) return r;
  const arr = parseJsonArray(r.text);
  if (!arr) return { ok: false, error: 'parse' };
  return { ok: true, lines: arr.slice(0, 3).map((x) => String(x)) };
}
