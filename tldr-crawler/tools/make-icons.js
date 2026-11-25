/*
 * tools/make-icons.js — regenerates icon16/48/128.png with zero dependencies.
 * Run: node tools/make-icons.js
 */
'use strict';

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body), 0);
  return Buffer.concat([len, body, crc]);
}

function encodePNG(w, h, rgba) {
  const stride = w * 4;
  const raw = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (stride + 1)] = 0;
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([SIG, chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}

/* ---- tiny software rasteriser (supersampled 3x) ---- */
const BLUE = [0x5a, 0xb8, 0xff];
const PINK = [0xff, 0x7a, 0xb8];
const BG = [0x16, 0x18, 0x1c];

function drawIcon(size) {
  const ss = 3;
  const W = size * ss;
  const buf = new Float32Array(W * W * 4);

  const put = (x, y, rgb, a) => {
    if (x < 0 || y < 0 || x >= W || y >= W || a <= 0) return;
    const i = (y * W + x) * 4;
    const inv = 1 - a;
    buf[i] = buf[i] * inv + rgb[0] * a;
    buf[i + 1] = buf[i + 1] * inv + rgb[1] * a;
    buf[i + 2] = buf[i + 2] * inv + rgb[2] * a;
    buf[i + 3] = Math.min(1, buf[i + 3] * inv + a);
  };

  const disc = (cx, cy, r, rgb, a) => {
    for (let y = Math.floor(cy - r - 1); y <= Math.ceil(cy + r + 1); y++) {
      for (let x = Math.floor(cx - r - 1); x <= Math.ceil(cx + r + 1); x++) {
        const d = Math.hypot(x + 0.5 - cx, y + 0.5 - cy);
        if (d <= r) put(x, y, rgb, a);
      }
    }
  };

  const line = (x0, y0, x1, y1, wd, rgb, a) => {
    const steps = Math.ceil(Math.hypot(x1 - x0, y1 - y0) * 2) + 1;
    for (let s = 0; s <= steps; s++) {
      const t = s / steps;
      disc(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, wd / 2, rgb, a);
    }
  };

  const u = (v) => v * W; // 0..1 -> device px

  // rounded dark plate
  const r = u(0.22);
  for (let y = 0; y < W; y++) {
    for (let x = 0; x < W; x++) {
      const dx = Math.max(r - (x + 0.5), 0, (x + 0.5) - (W - r));
      const dy = Math.max(r - (y + 0.5), 0, (y + 0.5) - (W - r));
      if (Math.hypot(dx, dy) <= r) put(x, y, BG, 1);
    }
  }

  const cx = u(0.5), cy = u(0.52), bw = u(0.085);

  // 8 legs, two segments, knees out
  const legs = [
    [0.30, 0.20], [0.34, 0.06], [0.52, 0.04], [0.68, 0.10],
    [0.30, 0.84], [0.36, 0.96], [0.54, 0.98], [0.70, 0.90]
  ];
  for (const [fx, fy] of legs) {
    const footX = u(fx), footY = u(fy);
    const kx = (cx + footX) / 2 + (footX < cx ? -u(0.06) : u(0.06));
    const ky = (cy + footY) / 2;
    line(cx, cy, kx, ky, bw * 0.55, BLUE, 1);
    line(kx, ky, footX, footY, bw * 0.5, BLUE, 1);
    disc(kx, ky, u(0.018), PINK, 1);
  }

  // abdomen + head
  disc(cx - u(0.13), cy, u(0.115), BLUE, 1);
  disc(cx, cy, u(0.085), BLUE, 1);
  disc(cx + u(0.11), cy, u(0.062), BLUE, 1);
  disc(cx - u(0.13), cy, u(0.075), BG, 1);
  disc(cx, cy, u(0.05), BG, 1);

  // eyes
  disc(cx + u(0.12), cy - u(0.026), u(0.02), [255, 255, 255], 1);
  disc(cx + u(0.12), cy + u(0.026), u(0.02), [255, 255, 255], 1);
  disc(cx + u(0.128), cy - u(0.026), u(0.009), BG, 1);
  disc(cx + u(0.128), cy + u(0.026), u(0.009), BG, 1);

  // downsample
  const out = Buffer.alloc(size * size * 4);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let rr = 0, gg = 0, bb = 0, aa = 0;
      for (let sy = 0; sy < ss; sy++) {
        for (let sx = 0; sx < ss; sx++) {
          const i = ((y * ss + sy) * W + (x * ss + sx)) * 4;
          rr += buf[i]; gg += buf[i + 1]; bb += buf[i + 2]; aa += buf[i + 3];
        }
      }
      const n = ss * ss;
      const o = (y * size + x) * 4;
      out[o] = Math.round(rr / n);
      out[o + 1] = Math.round(gg / n);
      out[o + 2] = Math.round(bb / n);
      out[o + 3] = Math.round((aa / n) * 255);
    }
  }
  return encodePNG(size, size, out);
}

const root = path.join(__dirname, '..');
for (const size of [16, 48, 128]) {
  const file = path.join(root, `icon${size}.png`);
  fs.writeFileSync(file, drawIcon(size));
  console.log('wrote', file);
}
