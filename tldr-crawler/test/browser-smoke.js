/*
 * Browser smoke test for content.js.
 * Drives a real Chrome (via `obscura serve --port 9222`) over CDP:
 * injects core.js + content.js into test/fixture.html, steers the spider with
 * synthetic mouse moves, then verifies discovery, highlighting and the
 * complete teardown of the page.
 *
 * Run:  obscura serve --port 9222
 *       node test/browser-smoke.js
 */
'use strict';

const fs = require('fs');
const path = require('path');

const CDP = process.env.CDP_URL || 'http://127.0.0.1:9222';
const W = 1280, H = 800;
const root = path.join(__dirname, '..');
const fixture = 'file:///' + path.join(__dirname, 'fixture.html').replace(/\\/g, '/');

const failures = [];
const notes = [];
function check(name, ok, detail) {
  if (ok) console.log('  ok   ' + name + (detail ? '  (' + detail + ')' : ''));
  else { console.log('  FAIL ' + name + (detail ? '  (' + detail + ')' : '')); failures.push(name); }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const ver = await (await fetch(CDP + '/json/version')).json();
  const ws = new WebSocket(ver.webSocketDebuggerUrl);
  await new Promise((res, rej) => {
    ws.addEventListener('open', res, { once: true });
    ws.addEventListener('error', rej, { once: true });
  });

  let seq = 0;
  const pending = new Map();
  ws.addEventListener('message', (ev) => {
    let m;
    try { m = JSON.parse(ev.data); } catch (e) { return; }
    if (m.id && pending.has(m.id)) {
      const p = pending.get(m.id);
      pending.delete(m.id);
      if (m.error) p.rej(new Error(m.method + ': ' + JSON.stringify(m.error)));
      else p.res(m.result);
    }
  });
  const send = (method, params, sessionId) => new Promise((res, rej) => {
    const id = ++seq;
    pending.set(id, { res, rej });
    const msg = { id, method, params: params || {} };
    if (sessionId) msg.sessionId = sessionId;
    ws.send(JSON.stringify(msg));
  });

  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  await send('Page.enable', {}, sessionId);
  await send('Runtime.enable', {}, sessionId);
  await send('Emulation.setDeviceMetricsOverride',
    { width: W, height: H, deviceScaleFactor: 2, mobile: false }, sessionId);
  await send('Page.navigate', { url: fixture }, sessionId);
  await sleep(900);

  const evalJs = async (expression) => {
    const r = await send('Runtime.evaluate',
      { expression, returnByValue: true, awaitPromise: true, allowUnsafeEvalBlockedByCSP: true }, sessionId);
    if (r.exceptionDetails) throw new Error('page error: ' + JSON.stringify(r.exceptionDetails.exception));
    return r.result.value;
  };

  const probe = () => evalJs(`(() => {
    const host = document.querySelector('[data-tldr-host]');
    const sr = host && host.shadowRoot ? host.shadowRoot : null;
    const panel = sr ? sr.querySelector('.panel') : null;
    const canvas = sr ? sr.querySelector('canvas') : null;
    let painted = 0;
    if (canvas) {
      const d = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data;
      for (let i = 3; i < d.length; i += 4) if (d[i] > 10) painted++;
    }
    const hl = window.CSS && CSS.highlights ? CSS.highlights.get('tldr-found') : null;
    const ranges = hl ? Array.from(hl) : [];
    return {
      host: !!host,
      shadow: !!sr,
      panel: !!panel,
      canvas: canvas ? canvas.width + 'x' + canvas.height : null,
      painted,
      count: panel ? panel.querySelector('.count').textContent : null,
      barWidth: panel ? panel.querySelector('.bar i').style.width : null,
      items: panel ? Array.from(panel.querySelectorAll('.list li .t')).map((e) => e.textContent) : [],
      highlightTexts: ranges.map((r) => String(r)),
      highlightStyleTag: !!document.querySelector('style[data-tldr="highlight"]'),
      glitchSpans: document.querySelectorAll('span[data-tldr-glitch]').length,
      styleEls: document.querySelectorAll('style[data-tldr]').length,
      articleHTML: document.getElementById('article').innerHTML
    };
  })()`);

  const articleBefore = await evalJs(`document.getElementById('article').innerHTML`);

  // This headless build ignores `pointer-events: none` (and even `visibility`)
  // during hit testing, so an overlay that real Chrome would look straight
  // through blocks elementFromPoint. Pull the overlay out of the tree for the
  // duration of those calls to emulate real Chrome hit testing; everything else
  // is the real code path.
  const needsHitTestShim = await evalJs(`(() => {
    const d = document.createElement('div');
    d.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:2147483646';
    document.documentElement.appendChild(d);
    const hit = document.elementFromPoint(500, 300);
    d.remove();
    return hit === d;
  })()`);
  if (needsHitTestShim) {
    await evalJs(`(() => {
      const origOne = Document.prototype.elementFromPoint;
      const origAll = Document.prototype.elementsFromPoint;
      const wrap = (orig) => function (x, y) {
        const h = document.querySelector('[data-tldr-host]');
        const parent = h && h.parentNode;
        if (h) h.remove();
        try { return orig.call(this, x, y); } finally { if (h && parent) parent.appendChild(h); }
      };
      Document.prototype.elementFromPoint = wrap(origOne);
      Document.prototype.elementsFromPoint = wrap(origAll);
    })(); 0`);
  }
  const hasHighlightApi = await evalJs(`!!(window.CSS && CSS.highlights && typeof window.Highlight === 'function')`);

  console.log('\n1. inject core.js + content.js');
  await evalJs(fs.readFileSync(path.join(root, 'core.js'), 'utf8') + '\n;0');
  await evalJs(fs.readFileSync(path.join(root, 'content.js'), 'utf8') + '\n;0');
  await sleep(300);
  let p = await probe();
  check('shadow host created', p.host && p.shadow);
  check('panel rendered inside the shadow root', p.panel);
  check('full-screen canvas sized for dpr 2', p.canvas === (W * 2) + 'x' + (H * 2), p.canvas);
  check('highlight stylesheet injected into the page tree', hasHighlightApi ? p.highlightStyleTag : true,
    hasHighlightApi ? '' : 'this build has no CSS Custom Highlight API - canvas fallback active');
  check('spider is painted', p.painted > 200, p.painted + ' px');
  const t0 = Number(String(p.count).split('/')[1]);
  check('counter reads found / total', /^\d+ \/ \d+$/.test(String(p.count)), p.count);
  check('sentence pool is the article only (12 sentences -> 5 key)', t0 === 5, p.count);

  console.log('\n2. steer the spider across the article');
  const move = (x, y) => send('Input.dispatchMouseEvent',
    { type: 'mouseMoved', x, y, button: 'none', buttons: 0 }, sessionId);
  for (const col of [260, 500, 740]) {
    for (let y = 140; y <= 720; y += 45) {
      await move(col, y);
      await sleep(90);
    }
  }
  await sleep(1200);
  p = await probe();
  const found = Number(String(p.count).split('/')[0].trim());
  check('spider found key sentences', found >= 1, p.count);
  check('found sentences are highlighted', hasHighlightApi ? p.highlightTexts.length === found : p.painted > 0,
    hasHighlightApi ? p.highlightTexts.length + ' ranges' : 'canvas fallback (no Highlight API in this build)');
  check('progress bar advanced', p.barWidth && p.barWidth !== '0%', p.barWidth);
  check('panel lists the discovered TL;DR fragments', p.items.length === found, p.items.length + ' items');
  check('TL;DR fragments respect the 9 word limit',
    p.items.every((t) => t.split(/\s+/).length <= 9), JSON.stringify(p.items[0] || ''));

  const joined = (p.highlightTexts.join(' ') + ' ' + p.items.join(' '));
  check('nav text was skipped', !/NAV-ONLY/.test(joined));
  check('sidebar text was skipped', !/SIDEBAR-ONLY/.test(joined));
  check('hidden text was skipped', !/HIDDEN-ONLY/.test(joined) && !/777/.test(joined));
  check('preformatted text was skipped', !/PRE-ONLY/.test(joined) && !/555/.test(joined));
  check('footer text was skipped', !/FOOTER-ONLY/.test(joined));
  if (hasHighlightApi) {
    check('highlight text is really page text',
      p.highlightTexts.every((t) => articleBefore.includes(t.slice(0, 20))),
      p.highlightTexts[0] ? JSON.stringify(p.highlightTexts[0].slice(0, 40)) : 'none');
  }
  notes.push('glitch spans while running: ' + p.glitchSpans);

  console.log('\n3. toggle off (inject content.js again)');
  await evalJs(fs.readFileSync(path.join(root, 'content.js'), 'utf8') + '\n;0');
  await sleep(300);
  const after = await evalJs(`(() => ({
    host: !!document.querySelector('[data-tldr-host]'),
    styleEls: document.querySelectorAll('style[data-tldr]').length,
    glitches: document.querySelectorAll('span[data-tldr-glitch]').length,
    highlights: !!(window.CSS && CSS.highlights && CSS.highlights.has('tldr-found')),
    articleHTML: document.getElementById('article').innerHTML,
    bodyText: document.body.innerText.length
  }))()`);
  check('shadow host removed', !after.host);
  check('injected styles removed', after.styleEls === 0, String(after.styleEls));
  check('glitch spans reverted', after.glitches === 0, String(after.glitches));
  check('CSS highlight registry cleared', !after.highlights);
  check('page text restored byte for byte', after.articleHTML === articleBefore);
  check('spider stopped (canvas gone)', !(await evalJs(`!!document.querySelector('canvas')`)));

  console.log('\n4. inject a second time (fresh instance)');
  await evalJs(fs.readFileSync(path.join(root, 'content.js'), 'utf8') + '\n;0');
  await sleep(400);
  const again = await probe();
  check('crawler can start again after teardown', again.host && again.panel && again.painted > 200, again.count);
  await evalJs(fs.readFileSync(path.join(root, 'content.js'), 'utf8') + '\n;0');
  await sleep(200);
  check('and stop again cleanly', !(await evalJs(`!!document.querySelector('[data-tldr-host]')`)));

  await send('Target.closeTarget', { targetId });
  ws.close();

  console.log('');
  for (const n of notes) console.log('note: ' + n);
  if (failures.length) {
    console.log('\nSMOKE TEST FAILED: ' + failures.length + ' check(s) -> ' + failures.join(' | '));
    process.exitCode = 1;
  } else {
    console.log('\nSMOKE TEST PASSED');
  }
}

main().catch((e) => {
  console.error('smoke test error:', e && e.message || e);
  process.exitCode = 2;
});
