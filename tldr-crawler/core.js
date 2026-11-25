/*
 * TL;DR Crawler - core.js
 * Pure, DOM-free helpers. Loaded before content.js in the page's isolated world
 * and requireable from Node for the self-check in test/core.test.js.
 */
(function (root) {
  'use strict';

  /* ---------------- sentences ---------------- */

  // Split a text blob into sentences. Returns [{text, start, end}] with the
  // offsets pointing at the original string so callers can map them onto
  // text nodes. Handles latin and CJK terminators.
  var SENT_RE = /[^.!?…。！？\n]+[.!?…。！？]+["'”’)\]]*|\S[^.!?…。！？\n]*$/g;

  function splitSentences(text) {
    var out = [];
    if (!text) return out;
    SENT_RE.lastIndex = 0;
    var m;
    while ((m = SENT_RE.exec(text)) !== null) {
      if (m[0] === '') { SENT_RE.lastIndex++; continue; }
      var raw = m[0];
      var start = m.index;
      var lead = raw.length - raw.replace(/^\s+/, '').length;
      start += lead;
      raw = raw.slice(lead);
      var body = raw.replace(/\s+$/, '');
      // drop punctuation-only fragments
      if (body.replace(/[^\p{L}\p{N}]/gu, '').length >= 2) {
        out.push({ text: body, start: start, end: start + body.length });
      }
      if (SENT_RE.lastIndex === m.index) SENT_RE.lastIndex++;
    }
    return out;
  }

  /* ---------------- scoring ---------------- */

  var CJK_TERMS = ['第一', '记录', '启动', '宣布', '新的', '唯一', '最大的', '最快的', '警告', '提高', '削减'];
  var EN_TERMS = ['first', 'record', 'launch', 'announce', 'new', 'only', 'largest', 'fastest', 'warn', 'warning', 'increase', 'cut'];
  var EN_RES = EN_TERMS.map(function (t) { return new RegExp('\\b' + t + '\\b', 'gi'); });

  function scoreSentence(text) {
    var t = String(text || '');
    var s = 0;
    if (/\d/.test(t)) s += 2;
    if (/%/.test(t)) s += 2;
    if (/\$/.test(t)) s += 2;
    if (/€/.test(t)) s += 2;
    if (/百万|million/i.test(t)) s += 2;
    if (/十亿|billion/i.test(t)) s += 2;

    for (var i = 0; i < CJK_TERMS.length; i++) {
      var term = CJK_TERMS[i], at = 0;
      while ((at = t.indexOf(term, at)) !== -1) { s += 1.5; at += term.length; }
    }
    for (var j = 0; j < EN_RES.length; j++) {
      var hits = t.match(EN_RES[j]);
      if (hits) s += hits.length * 1.5;
    }

    var caps = t.match(/[A-Z]/g);
    s += Math.min(2, (caps ? caps.length : 0) * 0.3);

    var len = t.trim().length;
    if (len < 40) s -= 2;
    if (len > 260) s -= 2;
    return s;
  }

  // Pick which sentences are "key". items: [{score, para}] -> sorted index list.
  // One representative per paragraph protects spatial spread, then fill by rank.
  function pickKey(items, opts) {
    opts = opts || {};
    var ratio = opts.ratio == null ? 0.25 : opts.ratio;
    var min = opts.min == null ? 5 : opts.min;
    var max = opts.max == null ? 80 : opts.max;
    var n = items.length;
    if (!n) return [];
    var quota = Math.max(min, Math.min(max, Math.round(n * ratio)));
    quota = Math.min(quota, n);

    var order = [];
    for (var i = 0; i < n; i++) order.push(i);
    order.sort(function (a, b) { return items[b].score - items[a].score || a - b; });

    var bestByPara = new Map();
    for (var k = 0; k < order.length; k++) {
      var p = items[order[k]].para;
      if (!bestByPara.has(p)) bestByPara.set(p, order[k]);
    }
    var reps = Array.from(bestByPara.values()).sort(function (a, b) { return items[b].score - items[a].score || a - b; });

    var chosen = new Set();
    for (var r = 0; r < reps.length && chosen.size < quota; r++) {
      if (items[reps[r]].score > 0) chosen.add(reps[r]);
    }
    for (var f = 0; f < order.length && chosen.size < quota; f++) chosen.add(order[f]);

    return Array.from(chosen).sort(function (a, b) { return a - b; });
  }

  /* ---------------- summaries ---------------- */

  var FILLERS = /^(?:and|but|however|also|so|then|yet|moreover|furthermore|in addition|additionally|meanwhile|therefore|thus|hence|according to|as a result|in fact|of course|well|now)\b[\s,:;\u2014-]*/i;

  function limitWords(text, maxWords) {
    var t = String(text == null ? '' : text).trim()
      .replace(/^["'“”‘’(\[\-\u2013\u2014\s]+/, '')
      .replace(/\s+/g, ' ');
    if (!t) return '';
    if (typeof Intl !== 'undefined' && typeof Intl.Segmenter === 'function') {
      try {
        var seg = new Intl.Segmenter(undefined, { granularity: 'word' });
        var words = [];
        var it = seg.segment(t), step;
        while (!(step = it.next()).done) if (step.value.isWordLike) words.push(step.value);
        if (words.length <= maxWords) return t.replace(/[.!?。！？…]+$/, '');
        var last = words[maxWords - 1];
        return t.slice(0, last.index + last.segment.length) + '…';
      } catch (e) { /* fall through to whitespace split */ }
    }
    var parts = t.split(/\s+/);
    if (parts.length <= maxWords) return t.replace(/[.!?。！？…]+$/, '');
    return parts.slice(0, maxWords).join(' ') + '…';
  }

  function fallbackSummary(text, maxWords) {
    var t = String(text == null ? '' : text).trim();
    var before;
    do { before = t; t = t.replace(FILLERS, ''); } while (t !== before && t);
    return limitWords(t, maxWords == null ? 9 : maxWords);
  }

  /* ---------------- spider maths ---------------- */

  // A "word" is a whole latin token, or a single CJK character (CJK has no spaces,
  // so a \p{L} run would swallow the whole clause).
  var CJK_CHAR = '[\\u3400-\\u9FFF\\uF900-\\uFAFF\\u3040-\\u30FF\\uAC00-\\uD7AF]';
  var WORD_RE = new RegExp(CJK_CHAR + '|[\\p{L}\\p{N}][\\p{L}\\p{N}\\u2019\'\\-]*', 'gu');
  var CJK_ONLY = new RegExp('^' + CJK_CHAR + '+$');

  // Word covering `offset` in `data` (or the word just before it).
  function extractWord(data, offset) {
    data = String(data == null ? '' : data);
    if (!data) return null;
    var re = new RegExp(WORD_RE.source, 'gu');
    var last = null, m;
    while ((m = re.exec(data)) !== null) {
      var s = m.index, e = m.index + m[0].length;
      if (offset >= s && offset <= e) return { start: s, end: e, word: m[0] };
      if (e <= offset) last = { start: s, end: e, word: m[0] };
      if (s > offset) break;
      if (m[0] === '') re.lastIndex++;
    }
    return last;
  }

  // Two-bone IK. `ox, oy` is the body centre: the knee bends away from it.
  function solveIK(hx, hy, fx, fy, l1, l2, ox, oy) {
    var dx = fx - hx, dy = fy - hy;
    var d = Math.sqrt(dx * dx + dy * dy);
    var reach = (l1 + l2) * 0.999;
    if (!(d > 1e-4)) { d = 1e-4; dx = 1e-4; dy = 0; }
    if (d > reach) { var k = reach / d; dx *= k; dy *= k; d = reach; }
    var ux = dx / d, uy = dy / d;
    var a = (l1 * l1 - l2 * l2 + d * d) / (2 * d);
    var h = Math.sqrt(Math.max(0, l1 * l1 - a * a));
    var bx = hx + ux * a, by = hy + uy * a;
    var k1x = bx - uy * h, k1y = by + ux * h;
    var k2x = bx + uy * h, k2y = by - ux * h;
    var d1 = (k1x - ox) * (k1x - ox) + (k1y - oy) * (k1y - oy);
    var d2 = (k2x - ox) * (k2x - ox) + (k2y - oy) * (k2y - oy);
    return {
      knee: d1 >= d2 ? { x: k1x, y: k1y } : { x: k2x, y: k2y },
      foot: { x: hx + dx, y: hy + dy }
    };
  }

  var Core = {
    splitSentences: splitSentences,
    scoreSentence: scoreSentence,
    pickKey: pickKey,
    limitWords: limitWords,
    fallbackSummary: fallbackSummary,
    extractWord: extractWord,
    isCjkWord: function (w) { return CJK_ONLY.test(String(w || '')); },
    solveIK: solveIK
  };

  root.TLDRCore = Core;
  if (typeof module === 'object' && module.exports) module.exports = Core;
})(typeof globalThis !== 'undefined' ? globalThis : this);
