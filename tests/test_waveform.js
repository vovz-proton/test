const fs = require('node:fs');
const assert = require('node:assert/strict');
const path = require('node:path');

const source = fs.readFileSync(path.join(__dirname, '../Core/Src/dac_sine.c'), 'utf8');

function array(name) {
  const match = source.match(new RegExp(name + '\\[[^\\]]+\\]=\\{([\\s\\S]*?)\\}'));
  assert(match, name);
  return match[1].split(',').map(value => Number(value.trim())).filter(value => !Number.isNaN(value));
}

// 128-point sine table used for phase interpolation. Even points must repeat
// the original 32-point waveform, so phase zero is unchanged.
const sine = array('sine');
assert.equal(sine.length, 128);
const sine32 = Array.from({ length: 32 }, (_, k) => sine[4 * k]);
assert.deepEqual(sine32, [
  0, 6393, 12539, 18204, 23170, 27245, 30273, 32137, 32767, 32137, 30273,
  27245, 23170, 18204, 12539, 6393, 0, -6393, -12539, -18204, -23170, -27245,
  -30273, -32137, -32767, -32137, -30273, -27245, -23170, -18204, -12539, -6393
]);
assert.equal(Math.max(...sine), 32767);
assert.equal(Math.min(...sine), -32767);
for (let k = 0; k < 128; ++k) assert.equal(sine[k] + sine[(k + 64) & 127], 0);

// Same formula as build_periods() in dac_sine.c: 32 ARR values whose sum gives
// the requested frequency exactly over one period.
function periods(hz) {
  const total = Math.floor((72000000 + Math.floor(hz / 2)) / hz);
  const base = Math.floor(total / 32);
  const rem = total % 32;
  const result = [];
  let acc = 0;
  for (let i = 0; i < 32; ++i) {
    acc += rem;
    const extra = Math.floor(acc / 32);
    acc %= 32;
    result.push(base + extra - 1);
  }
  return result;
}

function clockSum(arr) {
  return arr.reduce((sum, value) => sum + value + 1, 0);
}

const p8 = periods(8000);
assert.equal(p8.length, 32);
assert.equal(clockSum(p8), 9000);
assert(p8.every(value => value === 280 || value === 281));
assert.equal(72000000 / clockSum(p8), 8000);

const p1k = periods(1000);
assert.equal(clockSum(p1k), 72000);
assert.equal(72000000 / clockSum(p1k), 1000);

const p100 = periods(100);
assert.equal(clockSum(p100), 720000);
assert(p100.every(value => value === 22499));

const p20k = periods(20000);
assert.equal(clockSum(p20k), 3600);
assert(p20k.every(value => value === 111 || value === 112));

for (let hz = 100; hz <= 20000; hz += 37) {
  const arr = periods(hz);
  assert.equal(clockSum(arr), Math.floor((72000000 + Math.floor(hz / 2)) / hz));
  assert(arr.every(value => value > 0 && value <= 65535));
}

// DAC pipeline: sample zero is preloaded, DMA starts with sample one.
let dhr = sine32[0];
let clocks = 0;
let edges = [];
let prevTrigger = false;
for (let i = 0; i < 32 * 20; ++i) {
  const output = dhr;
  const phase = i % 32;
  assert.equal(output, sine32[phase]);
  const trigger = phase < 16;
  if (trigger !== prevTrigger) {
    edges.push(clocks);
    assert.equal(output, 0);
  }
  prevTrigger = trigger;
  dhr = sine32[(phase + 1) % 32];
  clocks += p8[phase] + 1;
  if (phase === 31) assert.equal(clocks, (i + 1) / 32 * 9000);
}
for (let i = 1; i < edges.length; ++i) assert.equal(edges[i] - edges[i - 1], 4500);

// Phase interpolation, mirrored from sine_at() and build_tables(): phase in
// tenths of a degree, offset in 1/256 of a 128-point table entry.
function sineAt(pos) {
  pos = ((pos % 32768) + 32768) % 32768;
  const idx = (pos >> 8) & 127;
  const frac = pos & 255;
  const a = sine[idx], b = sine[(idx + 1) & 127];
  return (a * (256 - frac) + b * frac + 128) >> 8;
}
function phaseOffset(tenths) {
  return Math.trunc((tenths * 256 * 128) / 3600);
}

assert.equal(phaseOffset(450), 4096);
assert.equal(phaseOffset(-450), -4096);
assert.equal(phaseOffset(0), 0);

for (let i = 0; i < 32; ++i) {
  assert.equal(sineAt((i + 1) * 1024), sine32[(i + 1) & 31]);
}

for (let i = 0; i < 32; ++i) {
  for (const tenths of [10, 100, 225, 450, -225, -450]) {
    const pos = (i + 1) * 1024 + phaseOffset(tenths);
    const expected = Math.round(32767 * Math.sin(2 * Math.PI * ((i + 1) / 32 + tenths / 3600)));
    assert(Math.abs(sineAt(pos) - expected) <= 12,
      `phase ${tenths / 10} deg, sample ${i}: ${sineAt(pos)} vs ${expected}`);
  }
}

// A small phase step changes neighbouring samples by a small amount: this is
// what makes the ramp smooth even though the table is rebuilt in place.
for (let i = 0; i < 32; ++i) {
  const a = sineAt((i + 1) * 1024 + phaseOffset(0));
  const b = sineAt((i + 1) * 1024 + phaseOffset(1));
  assert(Math.abs(a - b) <= 60);
}

console.log('PASS: 128-point phase table, 32-sample DAC pipeline, exact 8 kHz clocks, frequency and phase model');
