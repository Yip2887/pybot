/* TL;DR Crawler - options.js */
'use strict';

const keyInput = document.getElementById('key');
const modelInput = document.getElementById('model');
const status = document.getElementById('status');
const DEFAULT_MODEL = 'claude-3-5-haiku-latest';

function flash(text) {
  status.textContent = text;
  setTimeout(() => { if (status.textContent === text) status.textContent = ''; }, 2500);
}

chrome.storage.local.get(['apiKey', 'model']).then((d) => {
  keyInput.value = typeof d.apiKey === 'string' ? d.apiKey : '';
  modelInput.value = typeof d.model === 'string' && d.model ? d.model : DEFAULT_MODEL;
}).catch(() => { modelInput.value = DEFAULT_MODEL; });

document.getElementById('save').addEventListener('click', async () => {
  const apiKey = keyInput.value.trim();
  const model = modelInput.value.trim() || DEFAULT_MODEL;
  await chrome.storage.local.set({ apiKey, model });
  modelInput.value = model;
  flash(apiKey ? '已保存 / Saved' : '已保存（无 Key，使用本地摘要）/ Saved (local fallback)');
});

document.getElementById('clear').addEventListener('click', async () => {
  await chrome.storage.local.set({ apiKey: '' });
  keyInput.value = '';
  flash('Key 已清除 / Key cleared');
});
