#!/usr/bin/env node
/**
 * gen_tc2.js — Generate timing_tc2_iq_in.hex and timing_tc2_ted.hex
 *
 * Strategy: TC0 (offset=0.0) already exists.  TC2 uses offset=-1.0.
 * The generator applies the offset as:
 *   t_new  = t_orig + offset
 *   signal_out[n] = interp(signal_in, t_orig[n] - offset)
 *               = interp(signal_in, n - (-1.0))
 *               = interp(signal_in, n + 1.0)
 *
 * Then the Gardner TED reference model is run on the TC2 samples.
 *
 * The scaling (divide by max_amp, multiply by SCALE) is done before the
 * interpolation in the original script, so we operate on the tc0 int16
 * samples directly and apply the same interpolation logic.
 *
 * NOTE: The original script scales BEFORE saving to tc0, so tc0 samples
 * are already the final scaled int16 values at offset=0.0.  The tc2
 * signal is the tc0 signal evaluated at fractional indices n+1.0.
 */

'use strict';

const fs   = require('fs');
const path = require('path');

const OUTDIR   = path.dirname(path.resolve(__filename));
const TC0_IQ   = path.join(OUTDIR, 'timing_tc0_iq_in.hex');

// ---------------------------------------------------------------------------
// Read TC0 IQ file: alternating I, Q lines (signed 16-bit hex, one per line)
// ---------------------------------------------------------------------------
const tc0Lines = fs.readFileSync(TC0_IQ, 'utf8').trim().split('\n');
const N_VALS   = tc0Lines.length;           // should be 256 (128 I, 128 Q pairs)
const N_SAMPLES = N_VALS / 2;               // 128 samples

const iBase = new Array(N_SAMPLES);
const qBase = new Array(N_SAMPLES);
for (let n = 0; n < N_SAMPLES; n++) {
  const iv = parseInt(tc0Lines[2 * n],     16);
  const qv = parseInt(tc0Lines[2 * n + 1], 16);
  // convert unsigned 16-bit to signed
  iBase[n] = iv > 0x7FFF ? iv - 0x10000 : iv;
  qBase[n] = qv > 0x7FFF ? qv - 0x10000 : qv;
}

// ---------------------------------------------------------------------------
// Apply timing offset = -1.0
// The original Python:
//   t_new  = t_orig + offset          (= t_orig - 1.0)
//   signal_out = interp(t_orig, t_new, signal_in)
//             = signal_in evaluated at positions such that t_new[j] = t_orig[n]
//             = signal_in[n - offset]  = signal_in[n + 1.0]
//
// So tc2[n] = interp(iBase, n + 1.0)
// ---------------------------------------------------------------------------
const OFFSET  = -1.0;          // late timing
const INT16_MAX =  32767;
const INT16_MIN = -32768;

function interp1d(arr, fIdx) {
  if (fIdx < 0 || fIdx >= arr.length - 1) return 0;
  const lo   = Math.floor(fIdx);
  const frac = fIdx - lo;
  return arr[lo] * (1 - frac) + arr[lo + 1] * frac;
}

const iOut = new Int16Array(N_SAMPLES);
const qOut = new Int16Array(N_SAMPLES);
for (let n = 0; n < N_SAMPLES; n++) {
  const fIdx = n - OFFSET;     // n + 1.0
  const iv   = interp1d(iBase, fIdx);
  const qv   = interp1d(qBase, fIdx);
  iOut[n] = Math.round(Math.max(INT16_MIN, Math.min(INT16_MAX, iv)));
  qOut[n] = Math.round(Math.max(INT16_MIN, Math.min(INT16_MAX, qv)));
}

// ---------------------------------------------------------------------------
// Gardner TED reference model (exact mirror of Python script)
// ---------------------------------------------------------------------------
function gardnerTEDReference(iSamp, qSamp) {
  const nTotal   = iSamp.length;
  let   ncoAcc   = 0;
  const NCO_STEP = 0x40000000;
  const MASK32   = 0xFFFFFFFF;

  let s0i = 0, s1i = 0, s2i = 0, s3i = 0;
  let s0q = 0, s1q = 0, s2q = 0, s3q = 0;
  const results = [];

  for (let n = 0; n < nTotal; n++) {
    const iIn   = iSamp[n];
    const qIn   = qSamp[n];
    const ncoSum = (ncoAcc + NCO_STEP) >>> 0;
    const ovf    = (ncoSum < ncoAcc) ? 1 : 0;

    if (ovf) {
      const iDiff    = iIn - s3i;
      const qDiff    = qIn - s3q;
      const tedSum   = s1i * iDiff + s1q * qDiff;
      // arithmetic right shift 18
      let   tedScaled = Math.floor(tedSum / (1 << 18));
      tedScaled = Math.max(-32768, Math.min(32767, tedScaled));
      results.push([n, tedScaled]);
    }

    ncoAcc = ncoSum;

    // shift registers
    s3i = s2i; s2i = s1i; s1i = s0i; s0i = iIn;
    s3q = s2q; s2q = s1q; s1q = s0q; s0q = qIn;
  }
  return results;
}

const tedList = gardnerTEDReference(iOut, qOut);

// ---------------------------------------------------------------------------
// Hex helpers
// ---------------------------------------------------------------------------
function toHex16(val) {
  return (val & 0xFFFF).toString(16).toUpperCase().padStart(4, '0');
}

// ---------------------------------------------------------------------------
// Write files
// ---------------------------------------------------------------------------
const iqPath  = path.join(OUTDIR, 'timing_tc2_iq_in.hex');
const tedPath = path.join(OUTDIR, 'timing_tc2_ted.hex');

let iqLines  = '';
for (let n = 0; n < N_SAMPLES; n++) {
  iqLines += toHex16(iOut[n]) + '\n';
  iqLines += toHex16(qOut[n]) + '\n';
}
fs.writeFileSync(iqPath, iqLines);

let tedLines = '';
for (const [, tv] of tedList) {
  tedLines += toHex16(tv) + '\n';
}
fs.writeFileSync(tedPath, tedLines);

// ---------------------------------------------------------------------------
// Sanity check
// ---------------------------------------------------------------------------
console.log('Gardner TED test vector generation — TC2 (late timing, offset=-1 sample)');
console.log('='.repeat(70));
console.log(`  Samples    : ${N_SAMPLES}`);
console.log(`  TED events : ${tedList.length}`);

if (tedList.length > 4) {
  const tedVals = tedList.slice(4).map(([, tv]) => tv);
  const meanTED = tedVals.reduce((a, b) => a + b, 0) / tedVals.length;
  console.log(`  Mean TED (skip first 4): ${meanTED.toFixed(1)}`);
  if (meanTED < 0) {
    console.log('  PASS: mean_ted < 0  (correct sign for late timing)');
  } else {
    console.log(`  WARNING: expected mean_ted < 0 for late timing, got ${meanTED.toFixed(1)}`);
    process.exit(1);
  }
}

console.log(`\nFiles written:`);
console.log(`  ${iqPath}`);
console.log(`  ${tedPath}`);
