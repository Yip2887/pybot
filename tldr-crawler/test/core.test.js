/*
 * Self-check for core.js. Run: node test/core.test.js
 * Plain asserts, no framework.
 */
'use strict';

const assert = require('assert');
const Core = require('../core.js');

/* --- sentence splitting keeps offsets that map back to the source --- */
{
  const text = 'OpenAI shipped a new model. It costs $20 per month, up 40%. 研究人员发现该系统的速度提高了 3 倍！Trailing fragment without a stop';
  const parts = Core.splitSentences(text);
  assert.ok(parts.length >= 4, 'expected >= 4 sentences, got ' + parts.length);
  for (const p of parts) {
    assert.strictEqual(text.slice(p.start, p.end), p.text, 'offsets must round-trip');
    assert.ok(p.text.trim() === p.text, 'no leading/trailing space');
  }
  assert.ok(parts.some((p) => p.text.includes('$20')));
  assert.ok(parts.some((p) => p.text.includes('提高')));
}

/* --- scoring rewards numbers / money / key words --- */
{
  const plain = Core.scoreSentence('The team met on Tuesday to talk about things and stuff for a while.');
  const rich = Core.scoreSentence('The company announced a record $2 billion increase, up 40%.');
  assert.ok(rich > plain, 'rich sentence must outrank plain: ' + rich + ' vs ' + plain);
  assert.ok(Core.scoreSentence('Short.') < 0, 'very short sentences are penalised');
  const long = Core.scoreSentence('x'.repeat(300) + ' 5');
  assert.ok(long < Core.scoreSentence('A 5 number inside a reasonably sized sentence that is long enough to pass.'), 'over-long penalty');
}

/* --- key selection: quota, spread, order --- */
{
  const items = [];
  for (let p = 0; p < 10; p++) for (let i = 0; i < 4; i++) items.push({ score: p * 4 + i, para: p });
  const picked = Core.pickKey(items, { ratio: 0.25, min: 5, max: 80 });
  assert.strictEqual(picked.length, 10, 'quota = round(40*0.25)');
  assert.deepStrictEqual(picked, picked.slice().sort((a, b) => a - b), 'returned in article order');
  const paras = new Set(picked.map((i) => items[i].para));
  assert.strictEqual(paras.size, 10, 'every paragraph gets a representative');

  const few = Core.pickKey([{ score: 1, para: 0 }, { score: 2, para: 0 }], { min: 5, max: 80 });
  assert.strictEqual(few.length, 2, 'never more than available');

  const many = [];
  for (let i = 0; i < 400; i++) many.push({ score: i, para: i });
  assert.strictEqual(Core.pickKey(many).length, 80, 'capped at 80');
  assert.strictEqual(Core.pickKey([]).length, 0);
}

/* --- fallback summary: filler stripped, <= 9 words, numbers kept --- */
{
  const s = Core.fallbackSummary('However, according to the report, the company earned $4.2 million in the first quarter of the year.', 9);
  assert.ok(!/^however/i.test(s), 'leading filler removed: ' + s);
  assert.ok(!/^according to/i.test(s), 'second filler removed: ' + s);
  assert.ok(s.includes('$4.2'), 'numbers preserved: ' + s);
  const words = s.replace(/…$/, '').trim().split(/\s+/);
  assert.ok(words.length <= 9, 'at most 9 words, got ' + words.length + ': ' + s);

  const short = Core.fallbackSummary('Revenue rose 12%.', 9);
  assert.strictEqual(short, 'Revenue rose 12%', 'short sentence passes through without the final period');

  const cjk = Core.limitWords('研究人员发现新系统的运行速度比上一代提高了三倍以上，这是一个非常重要的结论。', 9);
  assert.ok(cjk.length < 40, 'CJK summary is actually short: ' + cjk);

  const empty = Core.fallbackSummary('   ', 9);
  assert.strictEqual(empty, '');
}

/* --- word extraction under the spider's foot --- */
{
  const data = 'The quick brown fox';
  assert.strictEqual(Core.extractWord(data, 5).word, 'quick');
  assert.strictEqual(Core.extractWord(data, 9).word, 'quick');
  assert.strictEqual(Core.extractWord(data, 11).word, 'brown');
  assert.strictEqual(Core.extractWord(data, 0).word, 'The');
  const uni = '每只蜘蛛爬过 3 个段落';
  assert.strictEqual(Core.extractWord(uni, 7).word, '3');
  assert.strictEqual(Core.extractWord(uni, 2).word, '只', 'CJK: one character at a time');
  assert.strictEqual(Core.isCjkWord('蜘'), true);
  assert.strictEqual(Core.isCjkWord('quick'), false);
  assert.strictEqual(Core.extractWord(uni, 6).word, '过', 'cursor in the gap picks the word before it');
  assert.strictEqual(Core.extractWord('word', 4).word, 'word', 'offset at the end still hits the word');
  assert.strictEqual(Core.extractWord('do not', 0).word, 'do');
  assert.strictEqual(Core.extractWord('   ', 1), null);
}

/* --- IK: knee bends outward, foot is clamped to reach --- */
{
  const body = { x: 0, y: 0 };
  const s1 = Core.solveIK(10, 0, 60, 40, 30, 34, body.x, body.y);   // right side
  const s2 = Core.solveIK(10, 0, 60, -40, 30, 34, body.x, body.y);  // left side
  assert.ok(s1.knee.y > 0, 'right leg knee bows outward (down): ' + s1.knee.y);
  assert.ok(s2.knee.y < 0, 'left leg knee bows outward (up): ' + s2.knee.y);

  const far = Core.solveIK(0, 0, 1000, 0, 30, 34, 0, 0);
  const reach = Math.hypot(far.foot.x, far.foot.y);
  assert.ok(reach <= 64.001, 'foot clamped to bone reach, got ' + reach);
  assert.ok(reach > 60, 'still extends nearly fully');

  const knee = Core.solveIK(0, 0, 50, 0, 30, 34, 0, 0).knee;
  assert.ok(Math.abs(Math.hypot(knee.x, knee.y) - 30) < 0.01, 'knee sits at femur length');
  assert.ok(Math.abs(Math.hypot(50 - knee.x, knee.y) - 34) < 0.01, 'tibia reaches the foot');
}

console.log('core.js self-check: all assertions passed');
