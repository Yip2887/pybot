/*
 * TL;DR Crawler - content.js
 * Injected into the page by background.js on every toolbar click.
 * Self-toggling: second injection tears the whole thing down again.
 *
 * Everything the extension creates (shadow host, canvas, panel, highlights,
 * glitch spans, timers, listeners) is owned by this closure and removed in
 * destroy().
 */
(() => {
  'use strict';

  const FLAG = '__TLDR_CRAWLER__';
  if (window[FLAG]) {
    try { window[FLAG].destroy(); } finally { window[FLAG] = null; }
    return;
  }
  const Core = window.TLDRCore;
  if (!Core) { console.warn('[TL;DR Crawler] core.js was not injected'); return; }

  /* ------------------------------------------------------------------ *
   * config
   * ------------------------------------------------------------------ */
  const CFG = {
    crawlMs: 80,          // text check under the feet
    rescanMs: 1000,       // debounce for the MutationObserver
    maxSpeed: 420,        // px/s
    stopDistance: 40,
    stepTrigger: 80,
    stepMs: 130,
    idleMs: 8000,
    dt: 1 / 120,
    glitchChance: 0.25,
    maxGlitches: 200,     // ponytail: hard cap so a long session can't wrap half the page
    summaryWords: 9,
    aiDebounceMs: 1200,
    keyRatio: 0.25,
    minKey: 5,
    maxKey: 80
  };
  const COLOR = '#5ab8ff';
  const JOINT = '#ff7ab8';

  const reduceMotion = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  const speedCap = reduceMotion ? CFG.maxSpeed * 0.5 : CFG.maxSpeed;
  const stepDur = reduceMotion ? (CFG.stepMs / 1000) * 1.6 : CFG.stepMs / 1000;
  const glitchChance = reduceMotion ? CFG.glitchChance * 0.5 : CFG.glitchChance;

  const SKIP_SEL = [
    'nav', 'header', 'footer', 'aside', 'form', 'menu', 'script', 'style', 'pre', 'code',
    'kbd', 'samp', 'svg', 'canvas', 'noscript', 'template',
    '[role="navigation"]', '[role="banner"]', '[role="complementary"]', '[role="contentinfo"]',
    '[role="search"]', '[aria-hidden="true"]', '[hidden]',
    '.sidebar', '.menu', '.nav', '.ad', '.ads', '.advert', '.advertisement',
    '[class*="advert"]', '[id*="advert"]', '[class*="sponsor"]', '[id*="sponsor"]',
    '[data-tldr-host]'
  ].join(',');
  const BLOCK_SEL = 'p, li, blockquote, h2, h3, h4';

  /* ------------------------------------------------------------------ *
   * state
   * ------------------------------------------------------------------ */
  const S = {
    destroyed: false,
    raf: 0,
    acc: 0,
    last: 0,
    frameNo: 0,
    keys: [],
    total: 0,
    styleEl: null,
    aiTimer: 0,
    timers: new Set(),
    listeners: [],
    host: null,
    canvas: null,
    ctx: null,
    view: { w: window.innerWidth, h: window.innerHeight },
    scrollX: window.scrollX || 0,
    scrollY: window.scrollY || 0,
    mouse: { docX: 0, docY: 0, movedAt: -1e9, inside: false },
    body: { x: 0, y: 0, vx: 0, vy: 0, heading: 0, tx: 0, ty: 0, wanderUntil: 0 },
    legs: [],
    lastGroup: -1,
    speedCap: speedCap,
    stepDur: stepDur,
    blockByEl: new Map(),
    nodeToBlock: new Map(),
    found: [],
    glitches: [],
    glitchNodes: new WeakSet(),
    highlightSupported: false,
    highlight: null,
    rectCache: { at: 0, rects: [] },
    hasKey: false,
    aiPending: [],
    ui: null,
    observer: null,
    rescanTimer: 0,
    prevSample: { x: 0, y: 0, at: 0, dirty: true },
    lastFound: null
  };

  /* ------------------------------------------------------------------ *
   * small utils
   * ------------------------------------------------------------------ */
  const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
  const dist = (ax, ay, bx, by) => Math.hypot(ax - bx, ay - by);

  function later(fn, ms) {
    const id = setTimeout(() => { S.timers.delete(id); if (!S.destroyed) fn(); }, ms);
    S.timers.add(id);
    return id;
  }
  function every(fn, ms) {
    const id = setInterval(() => { if (!S.destroyed) fn(); }, ms);
    S.timers.add(id);
    return id;
  }
  function cancelTimer(id) { clearTimeout(id); clearInterval(id); S.timers.delete(id); }
  function on(target, type, fn, opts) {
    target.addEventListener(type, fn, opts);
    S.listeners.push([target, type, fn, opts]);
  }
  function textNodesOf(el) {
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, {
      acceptNode(n) { return n.data && n.data.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT; }
    });
    const nodes = [], starts = [];
    let txt = '', n;
    while ((n = walker.nextNode())) { starts.push(txt.length); nodes.push(n); txt += n.data; }
    return { nodes, starts, txt };
  }

  /* ------------------------------------------------------------------ *
   * page text -> blocks -> sentences (all offsets, no DOM wrapping)
   * ------------------------------------------------------------------ */
  function findRoot() {
    const art = document.querySelector('article');
    if (art && art.textContent.trim().length >= 400) return art;
    const main = document.querySelector('main, [role="main"]');
    if (main && main.textContent.trim().length >= 400) return main;

    // densest container: sum the paragraph text of every ancestor once
    const sums = new Map();
    for (const b of document.querySelectorAll('p, li, blockquote')) {
      if (b.closest(SKIP_SEL)) continue;
      const len = b.textContent.trim().length;
      if (!len) continue;
      let p = b.parentElement, depth = 0;
      while (p && depth++ < 60) { sums.set(p, (sums.get(p) || 0) + len); p = p.parentElement; }
    }
    let best = null, bestLen = 0;
    for (const [el, len] of sums) {
      const tag = el.tagName;
      if (tag !== 'DIV' && tag !== 'SECTION' && tag !== 'MAIN' && tag !== 'ARTICLE' && tag !== 'TD') continue;
      if (len > bestLen) { bestLen = len; best = el; }
    }
    if (!best) return document.body;

    // descend into the child that still holds most of that text
    let cur = best;
    for (let guard = 0; guard < 6; guard++) {
      let child = null, childLen = 0;
      for (const c of cur.children) {
        const len = sums.get(c) || 0;
        if (len > childLen) { childLen = len; child = c; }
      }
      if (!child || childLen < bestLen * 0.7) break;
      bestLen = childLen;
      cur = child;
    }
    return cur;
  }

  function collectBlocks(root) {
    const cands = Array.from(root.querySelectorAll(BLOCK_SEL));
    const set = new Set(cands);
    const out = [];
    for (const el of cands) {
      if (el.closest(SKIP_SEL)) continue;
      let p = el.parentElement, nested = false;
      while (p) { if (set.has(p)) { nested = true; break; } p = p.parentElement; }
      if (nested) continue; // keep the outermost block only
      if (!el.textContent || !el.textContent.trim()) continue;
      const cs = getComputedStyle(el);
      if (cs.display === 'none' || cs.visibility === 'hidden') continue;
      out.push(el);
    }
    return out;
  }

  function buildBlock(el) {
    const t = textNodesOf(el);
    if (!t.txt.trim()) return null;
    const block = { el, nodes: t.nodes, starts: t.starts, txt: t.txt, nodeIdx: new Map(), sentences: [], para: 0 };
    indexBlock(block, true);
    return block;
  }

  function reindexBlock(block) {
    indexBlock(block, false);
  }

  function indexBlock(block, first) {
    if (!first) for (const n of block.nodes) S.nodeToBlock.delete(n);
    const t = textNodesOf(block.el);
    block.nodes = t.nodes;
    block.starts = t.starts;
    block.txt = t.txt; // identical to before a glitch: the wrapped word stays in place
    block.nodeIdx = new Map();
    block.nodes.forEach((n, i) => { block.nodeIdx.set(n, i); S.nodeToBlock.set(n, block); });
  }

  // global char offset inside a block -> live text node + local offset
  function locate(block, off) {
    const nodes = block.nodes, starts = block.starts;
    if (!nodes.length) return null;
    if (off <= 0) return { i: 0, node: nodes[0], offset: 0 };
    const total = block.txt.length;
    if (off >= total) {
      const i = nodes.length - 1;
      return { i, node: nodes[i], offset: nodes[i].data.length };
    }
    let lo = 0, hi = starts.length - 1, idx = 0;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (starts[mid] <= off) { idx = mid; lo = mid + 1; } else hi = mid - 1;
    }
    let i = idx;
    while (i + 1 < nodes.length && starts[i + 1] <= off) i++;
    const node = nodes[i];
    return { i, node, offset: clamp(off - starts[i], 0, node.data.length) };
  }

  function addSentences(block) {
    const have = new Set(block.sentences.map((s) => s.cs));
    for (const part of Core.splitSentences(block.txt)) {
      if (have.has(part.start)) continue; // ponytail: char offset is the identity; rescan is idempotent
      block.sentences.push({
        block,
        cs: part.start,
        ce: part.end,
        text: part.text,
        para: block.para,
        art: 0,
        score: 0,
        key: false,
        found: false,
        summary: ''
      });
    }
  }

  function rangeOf(s) {
    const b = s.block;
    if (!b.nodes.length || s.ce <= s.cs) return null;
    const a = locate(b, s.cs);
    const z = locate(b, s.ce - 1);
    if (!a || !z) return null;
    try {
      const r = document.createRange();
      r.setStart(a.node, a.offset);
      r.setEnd(z.node, Math.min(z.node.data.length, z.offset + 1));
      return r;
    } catch (e) {
      return null;
    }
  }

  function scan() {
    if (S.destroyed) return;
    const root = findRoot();
    const live = [];
    for (const el of collectBlocks(root)) {
      let block = S.blockByEl.get(el);
      if (block) reindexBlock(block);
      else {
        block = buildBlock(el);
        if (!block) continue;
        S.blockByEl.set(el, block);
      }
      live.push(block);
      addSentences(block);
    }

    live.forEach((b, i) => { b.para = i; });
    let art = 0;
    const all = [];
    for (const b of live) {
      b.sentences.sort((x, y) => x.cs - y.cs);
      for (const s of b.sentences) { s.para = b.para; s.art = art++; s.score = Core.scoreSentence(s.text); all.push(s); }
    }

    const picked = Core.pickKey(all, { ratio: CFG.keyRatio, min: CFG.minKey, max: CFG.maxKey });
    const isKey = new Set(picked.map((i) => all[i]));
    for (const s of all) s.key = isKey.has(s) || s.found;

    S.keys = all.filter((s) => s.key);
    S.total = Math.max(S.keys.length, S.found.length);
    S.found = S.found.filter((s) => s.block.el.isConnected && s.found);
    renderList();
    refreshHighlights();
  }

  /* ------------------------------------------------------------------ *
   * highlights (CSS Custom Highlight API, canvas rects as fallback)
   * ------------------------------------------------------------------ */
  function initHighlights() {
    S.highlightSupported = !!(window.CSS && CSS.highlights && typeof window.Highlight === 'function');
    if (!S.highlightSupported) return;
    S.highlight = new Highlight();
    CSS.highlights.set('tldr-found', S.highlight);
    // highlight styles must live in the page tree, not in the shadow root
    const st = document.createElement('style');
    st.setAttribute('data-tldr', 'highlight');
    st.textContent = '::highlight(tldr-found){background-color:rgba(255,214,102,.45);}';
    document.head.appendChild(st);
    S.styleEl = st;
  }

  function refreshHighlights() {
    S.rectCache.at = 0;
    if (!S.highlightSupported) return;
    S.highlight.clear();
    for (const s of S.found) {
      const r = rangeOf(s);
      if (r) S.highlight.add(r);
    }
  }

  function fallbackRects() {
    const now = performance.now();
    if (now - S.rectCache.at < 250) return S.rectCache.rects;
    const rects = [];
    for (const s of S.found) {
      const r = rangeOf(s);
      if (!r) continue;
      const list = r.getClientRects();
      for (let i = 0; i < list.length && rects.length < 400; i++) {
        const c = list[i];
        if (c.width > 0 && c.height > 0) rects.push(c);
      }
    }
    S.rectCache = { at: now, rects };
    return rects;
  }

  /* ------------------------------------------------------------------ *
   * glitch
   * ------------------------------------------------------------------ */
  const GLITCH_EFFECTS = [
    (sp) => sp.style.setProperty('font-family', 'ui-monospace, Menlo, Consolas, monospace', 'important'),
    (sp) => sp.style.setProperty('text-shadow', '0 0 1px #5ab8ff, 0 0 7px #5ab8ff', 'important'),
    (sp) => sp.style.setProperty('background-color', 'rgba(90,184,255,.35)', 'important'),
    (sp) => {
      sp.style.setProperty('display', 'inline-block', 'important');
      sp.style.setProperty('transform', 'rotate(' + (Math.random() * 12 - 6).toFixed(1) + 'deg)', 'important');
    },
    (sp) => sp.style.setProperty('letter-spacing', '1.6px', 'important'),
    (sp) => sp.style.setProperty('filter', 'blur(.7px)', 'important'),
    (sp) => sp.style.setProperty('text-transform', 'uppercase', 'important')
  ];

  function maybeGlitch(node, offset, block) {
    const parent = node.parentElement;
    if (!parent) return;
    if (parent.closest('input, textarea, select, [contenteditable=""], [contenteditable="true"]')) return;
    if (Math.random() > glitchChance) return;

    const w = Core.extractWord(node.data, offset);
    if (!w || (!Core.isCjkWord(w.word) && w.word.length < 3)) return;

    // The 200-glitch cap unwinds everything rather than evicting single entries:
    // each record snapshots the text node it changed, so they only undo correctly
    // newest-first (a stack).
    if (S.glitches.length >= CFG.maxGlitches) revertAllGlitches();

    const data = node.data;
    const after = data.slice(w.end);
    const p = node.parentNode;
    if (!p) return;

    const span = document.createElement('span');
    span.setAttribute('data-tldr-glitch', '1');
    span.textContent = w.word;
    // at most two effects per word
    const idx = [0, 1, 2, 3, 4, 5, 6];
    for (let n = 0; n < 2; n++) {
      const pick = idx.splice(Math.floor(Math.random() * idx.length), 1)[0];
      GLITCH_EFFECTS[pick](span);
    }

    const afterNode = after ? document.createTextNode(after) : null;
    S.glitchNodes.add(node);
    if (afterNode) S.glitchNodes.add(afterNode);

    node.data = data.slice(0, w.start); // live ranges shift correctly; spans are rebuilt below
    p.insertBefore(span, node.nextSibling);
    if (afterNode) p.insertBefore(afterNode, span.nextSibling);

    S.glitches.push({ node, original: data, span, afterNode });
    if (block) reindexBlock(block);
    refreshHighlights();
  }

  function revertGlitch(rec) {
    const i = S.glitches.indexOf(rec);
    if (i >= 0) S.glitches.splice(i, 1);
    if (rec.span && rec.span.parentNode) rec.span.remove();
    if (rec.afterNode && rec.afterNode.parentNode) rec.afterNode.remove();
    if (rec.node && rec.node.isConnected) rec.node.data = rec.original;
  }

  function revertAllGlitches() {
    // newest-first: an older record's snapshot predates every newer one on the
    // same text node, so undoing out of order would write stale text back.
    while (S.glitches.length) revertGlitch(S.glitches[S.glitches.length - 1]);
  }

  /* ------------------------------------------------------------------ *
   * spider
   * ------------------------------------------------------------------ */
  const LEG_DEF = [
    { l1: 28, l2: 32, rx: 22, ry: 26, hx: 10 },
    { l1: 30, l2: 34, rx: 8, ry: 34, hx: 4 },
    { l1: 30, l2: 34, rx: -8, ry: 36, hx: -4 },
    { l1: 28, l2: 32, rx: -22, ry: 28, hx: -10 }
  ];

  function initSpider() {
    S.body.x = S.scrollX + S.view.w * 0.5;
    S.body.y = S.scrollY + S.view.h * 0.45;
    S.body.tx = S.body.x;
    S.body.ty = S.body.y;
    S.body.heading = 0;
    S.legs = [];
    for (const side of [1, -1]) {
      LEG_DEF.forEach((d, i) => {
        S.legs.push({
          side, i,
          group: (i + (side > 0 ? 0 : 1)) % 2,
          hip: { x: d.hx, y: side * 5.5 },
          rest: { x: d.rx, y: side * d.ry },
          l1: d.l1, l2: d.l2,
          foot: { x: 0, y: 0 }, from: { x: 0, y: 0 }, to: { x: 0, y: 0 },
          stepping: false, t: 0, lift: 0, err: 0, toeDir: 0
        });
      });
    }
    const c = Math.cos(S.body.heading), s = Math.sin(S.body.heading);
    for (const leg of S.legs) {
      leg.foot.x = S.body.x + leg.rest.x * c - leg.rest.y * s;
      leg.foot.y = S.body.y + leg.rest.x * s + leg.rest.y * c;
    }
  }

  function localToWorld(leg, local, out) {
    const c = Math.cos(S.body.heading), s = Math.sin(S.body.heading);
    out.x = S.body.x + local.x * c - local.y * s;
    out.y = S.body.y + local.x * s + local.y * c;
    return out;
  }

  function physics(dt, now) {
    const idle = !S.mouse.inside || now - S.mouse.movedAt >= CFG.idleMs;
    if (idle) {
      if (now >= S.body.wanderUntil) {
        S.body.wanderUntil = now + 2500 + Math.random() * 2500;
        const m = 70;
        S.body.tx = S.scrollX + m + Math.random() * Math.max(1, S.view.w - 2 * m);
        S.body.ty = S.scrollY + m + Math.random() * Math.max(1, S.view.h - 2 * m);
      }
    } else {
      S.body.tx = clamp(S.mouse.docX, S.scrollX + 24, S.scrollX + S.view.w - 24);
      S.body.ty = clamp(S.mouse.docY, S.scrollY + 24, S.scrollY + S.view.h - 24);
    }

    const dx = S.body.tx - S.body.x, dy = S.body.ty - S.body.y;
    const d = Math.hypot(dx, dy);
    let wx = 0, wy = 0;
    if (d > CFG.stopDistance) {
      const sp = Math.min(S.speedCap, d * 2.5);
      wx = (dx / d) * sp;
      wy = (dy / d) * sp;
    }
    const k = Math.min(1, 6 * dt);
    S.body.vx += (wx - S.body.vx) * k;
    S.body.vy += (wy - S.body.vy) * k;
    const v = Math.hypot(S.body.vx, S.body.vy);
    if (v > S.speedCap) { const f = S.speedCap / v; S.body.vx *= f; S.body.vy *= f; }
    S.body.x += S.body.vx * dt;
    S.body.y += S.body.vy * dt;

    if (v > 6) {
      const want = Math.atan2(S.body.vy, S.body.vx);
      let diff = want - S.body.heading;
      while (diff > Math.PI) diff -= Math.PI * 2;
      while (diff < -Math.PI) diff += Math.PI * 2;
      S.body.heading += diff * Math.min(1, 8 * dt);
    }
    updateLegs(dt, now);
  }

  const _ideal = { x: 0, y: 0 };
  const _hip = { x: 0, y: 0 };

  function updateLegs(dt, now) {
    const cur = S.legs.find((l) => l.stepping);
    if (cur) {
      cur.t += dt / S.stepDur;
      if (cur.t >= 1) {
        cur.t = 1; cur.stepping = false; cur.lift = 0;
        cur.foot.x = cur.to.x; cur.foot.y = cur.to.y;
        cur.toeDir = S.body.heading;      // toe points the way we are walking
        S.lastGroup = cur.group;
        S.prevSample.dirty = true;
        sampleFeet([cur]);                 // one text check per foot landing
      } else {
        const t = cur.t;
        const e = t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
        cur.foot.x = cur.from.x + (cur.to.x - cur.from.x) * e;
        cur.foot.y = cur.from.y + (cur.to.y - cur.from.y) * e;
        cur.lift = Math.sin(Math.PI * t) * 6;  // reads as the foot leaving the ground
      }
      return; // rule: never more than one leg in the air
    }

    let best = null, bestScore = 0;
    for (const leg of S.legs) {
      localToWorld(leg, leg.rest, _ideal);
      leg.err = dist(_ideal.x, _ideal.y, leg.foot.x, leg.foot.y);
      const bias = leg.group !== S.lastGroup ? 1.15 : 1; // prefer alternating the two groups
      const score = leg.err * bias;
      if (leg.err > CFG.stepTrigger && score > bestScore) { bestScore = score; best = leg; }
    }
    if (!best) return;

    localToWorld(best, best.rest, _ideal);
    best.from.x = best.foot.x; best.from.y = best.foot.y;
    best.to.x = _ideal.x; best.to.y = _ideal.y;
    best.stepping = true;
    best.t = 0;
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  function drawLeg(ctx, leg) {
    const hw = localToWorld(leg, leg.hip, _hip);
    let fx = leg.foot.x, fy = leg.foot.y;
    const lift = leg.lift || 0;
    if (lift) {
      const ddx = hw.x - fx, ddy = hw.y - fy, dl = Math.hypot(ddx, ddy) || 1;
      fx += (ddx / dl) * lift;
      fy += (ddy / dl) * lift;
    }
    const sol = Core.solveIK(hw.x, hw.y, fx, fy, leg.l1, leg.l2, S.body.x, S.body.y);
    const shx = hw.x - S.scrollX, shy = hw.y - S.scrollY;
    const skx = sol.knee.x - S.scrollX, sky = sol.knee.y - S.scrollY;
    const sfx = fx - S.scrollX, sfy = fy - S.scrollY;

    ctx.save();
    ctx.globalAlpha = lift ? 0.6 : 1;
    ctx.strokeStyle = COLOR;
    ctx.lineWidth = 3;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.beginPath();
    ctx.moveTo(shx, shy);
    ctx.lineTo(skx, sky);
    ctx.lineTo(sfx, sfy);
    ctx.stroke();

    ctx.fillStyle = JOINT;
    ctx.beginPath(); ctx.arc(skx, sky, 2.6, 0, Math.PI * 2); ctx.fill();
    ctx.beginPath(); ctx.arc(shx, shy, 2, 0, Math.PI * 2); ctx.fill();

    if (!lift) {
      const gx = leg.foot.x - S.scrollX, gy = leg.foot.y - S.scrollY;
      ctx.strokeStyle = COLOR;
      ctx.lineWidth = 2.4;
      ctx.beginPath();
      ctx.moveTo(gx, gy);
      ctx.lineTo(gx + Math.cos(leg.toeDir) * 5, gy + Math.sin(leg.toeDir) * 5);
      ctx.stroke();
    }
    ctx.restore();
  }

  function drawBody(ctx) {
    ctx.save();
    ctx.translate(S.body.x - S.scrollX, S.body.y - S.scrollY);
    ctx.rotate(S.body.heading);
    ctx.strokeStyle = COLOR;
    ctx.lineWidth = 2.2;
    ctx.fillStyle = 'rgba(10,16,24,.45)';

    ctx.beginPath(); ctx.ellipse(-11, 0, 9.5, 7.5, 0, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
    roundRect(ctx, -3, -5, 10, 10, 3.5); ctx.fill(); ctx.stroke();
    ctx.beginPath(); ctx.arc(9, 0, 5, 0, Math.PI * 2); ctx.fill(); ctx.stroke();

    ctx.fillStyle = '#ffffff';
    ctx.beginPath(); ctx.arc(10, -2.4, 1.9, 0, Math.PI * 2); ctx.fill();
    ctx.beginPath(); ctx.arc(10, 2.4, 1.9, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = '#0f1115';
    ctx.beginPath(); ctx.arc(10.8, -2.4, 0.85, 0, Math.PI * 2); ctx.fill();
    ctx.beginPath(); ctx.arc(10.8, 2.4, 0.85, 0, Math.PI * 2); ctx.fill();
    ctx.restore();
  }

  function draw() {
    const ctx = S.ctx;
    if (!ctx) return;
    ctx.clearRect(0, 0, S.view.w, S.view.h);
    if (!S.highlightSupported) {
      ctx.save();
      ctx.fillStyle = 'rgba(255,214,102,.35)';
      for (const r of fallbackRects()) ctx.fillRect(r.left, r.top, r.width, r.height);
      ctx.restore();
    }
    for (const leg of S.legs) drawLeg(ctx, leg);
    drawBody(ctx);
  }

  /* ------------------------------------------------------------------ *
   * crawling: what is under the feet
   * ------------------------------------------------------------------ */
  function nearestTextNode(el) {
    if (!el || el.nodeType !== 1) return null;
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, {
      acceptNode(n) { return n.data && n.data.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT; }
    });
    const n = walker.nextNode();
    return n ? { node: n, offset: 0 } : null;
  }

  // Fallback for browsers without a caret API. ponytail: the offset inside the
  // line box is estimated from the x position, which is as precise as you can
  // get without caretRangeFromPoint.
  function nearestTextIn(el, x, y) {
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, {
      acceptNode(n) { return n.data && n.data.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT; }
    });
    let best = null, bestD = Infinity, node;
    while ((node = walker.nextNode())) {
      const range = document.createRange();
      range.selectNodeContents(node);
      const rects = range.getClientRects();
      for (let i = 0; i < rects.length; i++) {
        const r = rects[i];
        if (r.width <= 0 || r.height <= 0) continue;
        const dy = y < r.top ? r.top - y : y > r.bottom ? y - r.bottom : 0;
        const dx = x < r.left ? r.left - x : x > r.right ? x - r.right : 0;
        const d = dy * 4 + dx; // prefer the right line before the right column
        if (d < bestD) {
          const per = node.data.length / Math.max(1, rects.length);
          bestD = d;
          best = { node, offset: clamp(Math.round(per * (i + clamp((x - r.left) / r.width, 0, 1))), 0, node.data.length) };
        }
      }
    }
    return best;
  }

  function fallbackPoint(x, y) {
    const stack = document.elementsFromPoint
      ? document.elementsFromPoint(x, y)
      : [document.elementFromPoint(x, y)];
    for (const el of stack) {
      if (!el || el.nodeType !== 1) continue;
      if (el.closest && el.closest('[data-tldr-host]')) continue; // never read our own UI
      const hit = nearestTextIn(el, x, y);
      if (hit) return hit;
    }
    return null;
  }

  function hitTest(x, y) {
    let node = null, offset = 0;
    try {
      if (document.caretRangeFromPoint) {
        const r = document.caretRangeFromPoint(x, y);
        if (r) { node = r.startContainer; offset = r.startOffset; }
      } else if (document.caretPositionFromPoint) {
        const p = document.caretPositionFromPoint(x, y);
        if (p) { node = p.offsetNode; offset = p.offset; }
      }
    } catch (e) { node = null; }

    if (!node) return fallbackPoint(x, y);
    if (node.nodeType !== 3) return nearestTextNode(node);
    return { node, offset };
  }

  function onPoint(node, offset) {
    if (!node || node.nodeType !== 3) return false;
    const block = S.nodeToBlock.get(node);
    if (!block) return false;
    const i = block.nodeIdx.get(node);
    if (i == null) return false;
    const off = block.starts[i] + offset;

    for (const s of block.sentences) {
      if (!s.key || s.found) continue;
      if (off >= s.cs && off < s.ce) { markFound(s); return true; }
    }
    maybeGlitch(node, offset, block);
    return false;
  }

  function sampleFeet(legs) {
    for (const leg of legs) {
      const x = leg.foot.x - S.scrollX, y = leg.foot.y - S.scrollY;
      if (x < -4 || y < -4 || x > S.view.w + 4 || y > S.view.h + 4) continue;
      const hit = hitTest(x, y);
      if (hit && onPoint(hit.node, hit.offset)) return;
    }
  }

  function crawlTick() {
    if (S.destroyed || document.hidden) return;
    if (S.host && !S.host.isConnected) document.documentElement.appendChild(S.host); // SPA nuked it
    const now = performance.now();
    if (!S.prevSample.dirty) {
      const moved = dist(S.body.x, S.body.y, S.prevSample.x, S.prevSample.y);
      if (moved < 4 && now - S.prevSample.at < 500) return;
    }
    S.prevSample.dirty = false;
    S.prevSample.x = S.body.x;
    S.prevSample.y = S.body.y;
    S.prevSample.at = now;
    sampleFeet(S.legs);
  }

  function markFound(s) {
    if (s.found) return;
    s.found = true;
    s.summary = Core.fallbackSummary(s.text, CFG.summaryWords);
    S.found.push(s);
    S.lastFound = s;
    refreshHighlights();
    renderList();
    if (S.hasKey) queueAI(s);
  }

  /* ------------------------------------------------------------------ *
   * panel
   * ------------------------------------------------------------------ */
  const PANEL_CSS = `
    :host { all: initial; }
    .panel {
      position: fixed; top: 16px; right: 16px; width: 320px;
      max-width: calc(100vw - 32px); max-height: calc(100vh - 32px);
      display: flex; flex-direction: column; overflow: hidden;
      background: #16181c; color: #e7eaf0; border: 1px solid rgba(90,184,255,.35);
      border-radius: 12px; box-shadow: 0 14px 36px rgba(0,0,0,.5);
      font: 13px/1.45 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
      pointer-events: auto;
    }
    .head { display: flex; align-items: center; gap: 8px; padding: 10px 12px; cursor: move;
      user-select: none; background: #1b1e24; border-bottom: 1px solid rgba(255,255,255,.07); }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: #5ab8ff; box-shadow: 0 0 8px #5ab8ff; }
    h1 { margin: 0; font-size: 13px; font-weight: 700; letter-spacing: .16em; color: #ffd166; }
    .count { margin-left: auto; color: #9aa4b2; font-variant-numeric: tabular-nums; font-size: 12px; }
    .bar { height: 4px; background: rgba(255,255,255,.1); }
    .bar i { display: block; height: 100%; width: 0; background: #ff7ab8; transition: width .25s ease; }
    .listwrap { max-height: 38vh; overflow: auto; padding: 8px 0; }
    .list { list-style: none; margin: 0; padding: 0; }
    .list li { display: flex; gap: 8px; padding: 4px 12px; }
    .list li .n { color: #5ab8ff; min-width: 16px; font-variant-numeric: tabular-nums; }
    .list li.new { animation: tldr-flash 1.2s ease-out 2; }
    @keyframes tldr-flash { from { background: rgba(255,209,102,.55); } to { background: transparent; } }
    .empty { padding: 6px 12px 10px; color: #7c8595; }
    .ai-out { padding: 0 12px; color: #ffd166; white-space: pre-wrap; }
    .ai-out:not(:empty) { padding-bottom: 10px; border-top: 1px solid rgba(255,255,255,.07); padding-top: 10px; }
    .status { padding: 0 12px; color: #ff7ab8; font-size: 12px; }
    .status:not(:empty) { padding-bottom: 8px; }
    .btns { display: flex; flex-wrap: wrap; gap: 6px; padding: 10px 12px; border-top: 1px solid rgba(255,255,255,.07); }
    button { padding: 6px 10px; border-radius: 8px; cursor: pointer; font: inherit; font-size: 12px;
      border: 1px solid rgba(90,184,255,.45); background: rgba(90,184,255,.12); color: #cfe8ff; }
    button:hover { background: rgba(90,184,255,.24); }
    button[data-act="close"] { border-color: rgba(255,122,184,.5); background: rgba(255,122,184,.12); color: #ffd0e6; }
    button[data-act="ai"] { border-color: rgba(255,209,102,.5); background: rgba(255,209,102,.12); color: #ffe9b0; }
  `;

  function buildPanel(shadow) {
    const style = document.createElement('style');
    style.textContent = PANEL_CSS;
    shadow.appendChild(style);

    const panel = document.createElement('div');
    panel.className = 'panel';
    panel.innerHTML = [
      '<div class="head"><span class="dot"></span><h1>TL;DR</h1><span class="count">0 / 0</span></div>',
      '<div class="bar"><i></i></div>',
      '<div class="listwrap"><ol class="list"></ol><div class="empty">Move the cursor over the article — the spider reads as it crawls.</div></div>',
      '<div class="ai-out"></div>',
      '<div class="status"></div>',
      '<div class="btns">',
      '<button data-act="copy">复制 TL;DR</button>',
      '<button data-act="restart">重新启动</button>',
      '<button data-act="close">关闭</button>',
      '</div>'
    ].join('');
    shadow.appendChild(panel);

    S.ui = {
      panel,
      head: panel.querySelector('.head'),
      count: panel.querySelector('.count'),
      bar: panel.querySelector('.bar i'),
      list: panel.querySelector('.list'),
      empty: panel.querySelector('.empty'),
      aiOut: panel.querySelector('.ai-out'),
      status: panel.querySelector('.status'),
      btns: panel.querySelector('.btns')
    };

    // never let panel interaction leak into the page
    for (const type of ['pointerdown', 'mousedown', 'click', 'dblclick', 'selectstart', 'wheel']) {
      panel.addEventListener(type, (e) => e.stopPropagation());
    }

    let drag = null;
    const head = S.ui.head;
    head.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;
      const r = panel.getBoundingClientRect();
      drag = { dx: e.clientX - r.left, dy: e.clientY - r.top };
      panel.style.right = 'auto';
      panel.style.left = r.left + 'px';
      panel.style.top = r.top + 'px';
      try { head.setPointerCapture(e.pointerId); } catch (err) { /* ignore */ }
      e.preventDefault();
    });
    head.addEventListener('pointermove', (e) => {
      if (!drag) return;
      panel.style.left = clamp(e.clientX - drag.dx, 0, window.innerWidth - 60) + 'px';
      panel.style.top = clamp(e.clientY - drag.dy, 0, window.innerHeight - 30) + 'px';
    });
    head.addEventListener('pointerup', (e) => {
      drag = null;
      try { head.releasePointerCapture(e.pointerId); } catch (err) { /* ignore */ }
    });

    S.ui.btns.addEventListener('click', (e) => {
      const btn = e.target && e.target.closest ? e.target.closest('button[data-act]') : null;
      if (!btn) return;
      e.stopPropagation();
      const act = btn.getAttribute('data-act');
      if (act === 'copy') doCopy();
      else if (act === 'restart') restart();
      else if (act === 'close') destroy();
      else if (act === 'ai') runFinal();
    });
  }

  function addAiButton() {
    if (!S.ui || S.ui.btns.querySelector('button[data-act="ai"]')) return;
    const b = document.createElement('button');
    b.setAttribute('data-act', 'ai');
    b.textContent = '用 Claude 的语言写出 TL;DR';
    S.ui.btns.insertBefore(b, S.ui.btns.firstChild);
  }

  function showStatus(text, ms) {
    if (!S.ui) return;
    S.ui.status.textContent = text;
    if (ms) later(() => { if (S.ui && S.ui.status.textContent === text) S.ui.status.textContent = ''; }, ms);
  }

  function updateCounts() {
    if (!S.ui) return;
    const total = S.total || 0;
    S.ui.count.textContent = S.found.length + ' / ' + total;
    S.ui.bar.style.width = (total ? Math.round((S.found.length / total) * 100) : 0) + '%';
  }

  function renderList() {
    if (!S.ui) return;
    const items = S.found.slice().sort((a, b) => a.art - b.art);
    const list = S.ui.list;
    list.textContent = '';
    let flashEl = null;
    items.forEach((s, i) => {
      const li = document.createElement('li');
      const n = document.createElement('span');
      n.className = 'n';
      n.textContent = (i + 1) + '.';
      const t = document.createElement('span');
      t.className = 't';
      t.textContent = s.summary || s.text;
      li.appendChild(n);
      li.appendChild(t);
      if (s === S.lastFound) { li.classList.add('new'); flashEl = li; }
      list.appendChild(li);
    });
    S.ui.empty.style.display = items.length ? 'none' : 'block';
    updateCounts();
    if (flashEl) flashEl.scrollIntoView({ block: 'nearest' });
  }

  async function doCopy() {
    const items = S.found.slice().sort((a, b) => a.art - b.art);
    if (!items.length) { showStatus('还没有发现内容 / nothing yet', 2000); return; }
    const text = items.map((s, i) => (i + 1) + '. ' + (s.summary || s.text)).join('\n');
    let ok = false;
    try { await navigator.clipboard.writeText(text); ok = true; } catch (e) { ok = false; }
    if (!ok) {
      try {
        const ta = document.createElement('textarea');
        ta.setAttribute('data-tldr', 'copy');
        ta.value = text;
        ta.style.cssText = 'position:fixed;left:-9999px;top:0;';
        document.body.appendChild(ta);
        ta.select();
        ok = document.execCommand('copy');
        ta.remove();
      } catch (e) { ok = false; }
    }
    showStatus(ok ? '已复制 / copied' : '复制失败 / copy failed', 2000);
  }

  /* ------------------------------------------------------------------ *
   * Anthropic side (all network work happens in background.js)
   * ------------------------------------------------------------------ */
  function sendBg(payload) {
    return new Promise((resolve) => {
      try {
        chrome.runtime.sendMessage(payload, (res) => {
          if (chrome.runtime.lastError) { resolve({ ok: false, error: 'runtime' }); return; }
          resolve(res || { ok: false, error: 'empty' });
        });
      } catch (e) {
        resolve({ ok: false, error: 'threw' });
      }
    });
  }

  function queueAI(s) {
    S.aiPending.push(s);
    cancelTimer(S.aiTimer);
    S.aiTimer = later(flushAI, CFG.aiDebounceMs);
  }

  async function flushAI() {
    if (!S.aiPending.length) return;
    const batch = S.aiPending.splice(0, 20);
    const res = await sendBg({ type: 'tldr:summarize', sentences: batch.map((s) => s.text) });
    if (res && res.ok && Array.isArray(res.summaries)) {
      batch.forEach((s, i) => {
        const v = res.summaries[i];
        if (typeof v === 'string' && v.trim()) s.summary = Core.limitWords(v.trim(), CFG.summaryWords);
      });
      renderList();
    } else if (res && res.error && res.error !== 'no-key') {
      showStatus('AI 不可用', 4000);
    }
  }

  async function runFinal() {
    const items = S.found.slice().sort((a, b) => a.art - b.art);
    if (!items.length) { showStatus('还没有发现关键句 / nothing found yet', 2000); return; }
    S.ui.aiOut.textContent = '思考中…';
    const res = await sendBg({ type: 'tldr:final', sentences: items.map((s) => s.text) });
    if (res && res.ok && Array.isArray(res.lines) && res.lines.length) {
      S.ui.aiOut.textContent = res.lines.map((l) => '• ' + l).join('\n');
    } else {
      S.ui.aiOut.textContent = '';
      showStatus('AI 不可用', 4000); // fallback summaries stay untouched
    }
  }

  /* ------------------------------------------------------------------ *
   * lifecycle
   * ------------------------------------------------------------------ */
  function buildHost() {
    const host = document.createElement('div');
    host.setAttribute('data-tldr-host', '1');
    host.style.cssText =
      'position:fixed;top:0;left:0;width:100%;height:100%;pointer-events:none;z-index:2147483646;';
    const shadow = host.attachShadow({ mode: 'open' });
    const canvas = document.createElement('canvas');
    canvas.style.cssText = 'position:absolute;left:0;top:0;width:100%;height:100%;display:block;pointer-events:none;';
    shadow.appendChild(canvas);
    buildPanel(shadow);
    document.documentElement.appendChild(host);
    S.host = host;
    S.canvas = canvas;
    S.ctx = canvas.getContext('2d');
    resize();
  }

  function resize() {
    if (!S.canvas) return;
    const dpr = window.devicePixelRatio || 1;
    S.view.w = window.innerWidth;
    S.view.h = window.innerHeight;
    S.canvas.width = Math.max(1, Math.round(S.view.w * dpr));
    S.canvas.height = Math.max(1, Math.round(S.view.h * dpr));
    S.canvas.style.width = S.view.w + 'px';
    S.canvas.style.height = S.view.h + 'px';
    S.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    S.rectCache.at = 0;
  }

  function readScroll() {
    S.scrollX = window.scrollX || window.pageXOffset || 0;
    S.scrollY = window.scrollY || window.pageYOffset || 0;
  }

  function isOurMutation(m) {
    if (m.type === 'childList') {
      const nodes = [];
      m.addedNodes.forEach((n) => nodes.push(n));
      m.removedNodes.forEach((n) => nodes.push(n));
      if (!nodes.length) return true;
      return nodes.every((n) =>
        (n.nodeType === 1 && n.hasAttribute &&
          (n.hasAttribute('data-tldr-glitch') || n.hasAttribute('data-tldr'))) ||
        (n.nodeType === 3 && S.glitchNodes.has(n))
      );
    }
    if (m.type === 'characterData') return S.glitchNodes.has(m.target);
    return false;
  }

  function startObserver() {
    S.observer = new MutationObserver((records) => {
      if (S.destroyed) return;
      for (const m of records) {
        if (!isOurMutation(m)) {
          cancelTimer(S.rescanTimer);
          S.rescanTimer = later(() => { if (!S.destroyed) scan(); }, CFG.rescanMs);
          break;
        }
      }
    });
    // observe from body: SPA route changes can replace the whole root
    S.observer.observe(document.body, { childList: true, subtree: true, characterData: true });
  }

  function attachListeners() {
    on(window, 'mousemove', (e) => {
      readScroll();
      S.mouse.docX = e.clientX + S.scrollX;
      S.mouse.docY = e.clientY + S.scrollY;
      S.mouse.movedAt = performance.now();
      S.mouse.inside = true;
    }, { passive: true });
    on(window, 'mouseout', (e) => { if (!e.relatedTarget) S.mouse.inside = false; }, { passive: true });
    on(window, 'blur', () => { S.mouse.inside = false; });
    on(window, 'scroll', readScroll, { passive: true });
    on(document, 'scroll', readScroll, { passive: true, capture: true });
    on(window, 'resize', resize);
  }

  function frame(ts) {
    if (S.destroyed) return;
    S.raf = requestAnimationFrame(frame);
    try {
      if (!S.last) S.last = ts;
      let dms = ts - S.last;
      S.last = ts;
      if (dms > 250) dms = 250; // tab was throttled
      S.acc += dms / 1000;
      let guard = 0;
      while (S.acc >= CFG.dt && guard++ < 24) { physics(CFG.dt, ts); S.acc -= CFG.dt; }
      readScroll();
      S.frameNo = (S.frameNo || 0) + 1;
      if (reduceMotion && S.frameNo % 2) return; // lower animation frequency
      draw();
    } catch (err) {
      // never spam the console once per frame on a hostile page
      console.error('[TL;DR Crawler] render loop stopped:', err);
      cancelAnimationFrame(S.raf);
    }
  }

  function restart() {
    revertAllGlitches();
    for (const s of S.found) s.found = false;
    S.found = [];
    S.lastFound = null;
    S.total = 0;
    refreshHighlights();
    if (S.ui) { S.ui.list.textContent = ''; S.ui.aiOut.textContent = ''; showStatus(''); }
    renderList();
    scan();
    S.prevSample.dirty = true;
  }

  function destroy() {
    if (S.destroyed) return;
    S.destroyed = true;

    cancelAnimationFrame(S.raf);
    for (const id of Array.from(S.timers)) cancelTimer(id);
    if (S.observer) { S.observer.disconnect(); S.observer = null; }
    for (const [t, type, fn, opts] of S.listeners) t.removeEventListener(type, fn, opts);
    S.listeners = [];

    revertAllGlitches();

    if (S.highlightSupported) {
      try { CSS.highlights.delete('tldr-found'); } catch (e) { /* ignore */ }
      S.highlight = null;
    }
    if (S.styleEl && S.styleEl.parentNode) S.styleEl.remove();

    if (S.host && S.host.parentNode) S.host.remove();
    S.host = null;
    S.canvas = null;
    S.ctx = null;

    S.blockByEl.clear();
    S.nodeToBlock.clear();
    S.found = [];
    S.glitches = [];
    S.legs = [];
    S.ui = null;
  }

  /* ------------------------------------------------------------------ *
   * go
   * ------------------------------------------------------------------ */
  function boot() {
    buildHost();
    initHighlights();
    attachListeners();
    initSpider();
    scan();
    startObserver();
    every(crawlTick, CFG.crawlMs);
    S.raf = requestAnimationFrame(frame);
    sendBg({ type: 'tldr:config' }).then((res) => {
      if (S.destroyed) return;
      if (res && res.ok && res.hasKey) { S.hasKey = true; addAiButton(); }
    });
  }

  window[FLAG] = { destroy, restart };
  try {
    boot();
  } catch (err) {
    console.error('[TL;DR Crawler] failed to start:', err);
    try { destroy(); } catch (e) { /* ignore */ }
    window[FLAG] = null;
  }
})();
