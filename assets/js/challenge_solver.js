/**
 * The registration proof-of-work solver (P5-D1, `Baudrate.Auth.Challenge`).
 *
 * Finds a decimal `solution` such that SHA-256(nonce + solution) starts with
 * `bits` zero bits. The server checks the one hash that proves it.
 *
 * ## Why a hand-written SHA-256
 *
 * `crypto.subtle.digest` is asynchronous: each call returns a promise, and a
 * search of about a million hashes spends almost all of its time settling
 * them. The input here is always a single 64-byte block — a 32-character hex
 * nonce and a counter of at most a dozen digits — so one compression per
 * attempt, with no allocation in the loop, is what makes the search take a
 * second on a phone rather than a minute.
 *
 * Only the first word of the digest is ever needed: the difficulty is capped
 * at 22 bits, which all lie in H0. The server checks the full digest's leading
 * bits, and the first 32 of those *are* H0, so the two tests agree exactly.
 *
 * Shared by the Web Worker (`challenge_worker.js`) and by the hook's
 * main-thread fallback, so there is one implementation to be right or wrong.
 */

const K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
])

const H0 = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]

const W = new Uint32Array(64)
const block = new Uint8Array(64)

/**
 * The full SHA-256 of an ASCII string shorter than 56 bytes, as eight words.
 * Exported for the verification test; the search itself only reads word 0.
 */
export function sha256Words(ascii) {
  const len = ascii.length
  if (len > 55) throw new Error("challenge input must fit in one block")

  block.fill(0)
  for (let i = 0; i < len; i++) block[i] = ascii.charCodeAt(i)
  block[len] = 0x80
  // Message length in bits, big-endian, in the last eight bytes. It is under
  // 2^32 by construction, so only the final four bytes are ever non-zero.
  const bitLen = len * 8
  block[60] = (bitLen >>> 24) & 0xff
  block[61] = (bitLen >>> 16) & 0xff
  block[62] = (bitLen >>> 8) & 0xff
  block[63] = bitLen & 0xff

  for (let t = 0; t < 16; t++) {
    const j = t * 4
    W[t] = ((block[j] << 24) | (block[j + 1] << 16) | (block[j + 2] << 8) | block[j + 3]) >>> 0
  }
  for (let t = 16; t < 64; t++) {
    const w15 = W[t - 15]
    const w2 = W[t - 2]
    const s0 = ((w15 >>> 7) | (w15 << 25)) ^ ((w15 >>> 18) | (w15 << 14)) ^ (w15 >>> 3)
    const s1 = ((w2 >>> 17) | (w2 << 15)) ^ ((w2 >>> 19) | (w2 << 13)) ^ (w2 >>> 10)
    W[t] = (W[t - 16] + s0 + W[t - 7] + s1) >>> 0
  }

  let a = H0[0], b = H0[1], c = H0[2], d = H0[3]
  let e = H0[4], f = H0[5], g = H0[6], h = H0[7]

  for (let t = 0; t < 64; t++) {
    const S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7))
    const ch = (e & f) ^ (~e & g)
    const t1 = (h + S1 + ch + K[t] + W[t]) >>> 0
    const S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10))
    const maj = (a & b) ^ (a & c) ^ (b & c)
    const t2 = (S0 + maj) >>> 0

    h = g
    g = f
    f = e
    e = (d + t1) >>> 0
    d = c
    c = b
    b = a
    a = (t1 + t2) >>> 0
  }

  return [
    (H0[0] + a) >>> 0, (H0[1] + b) >>> 0, (H0[2] + c) >>> 0, (H0[3] + d) >>> 0,
    (H0[4] + e) >>> 0, (H0[5] + f) >>> 0, (H0[6] + g) >>> 0, (H0[7] + h) >>> 0,
  ]
}

/**
 * Tries `count` consecutive counters starting at `start`.
 * Returns the winning solution as a string, or null when none in the batch won.
 */
export function solveBatch(nonce, bits, start, count) {
  const shift = 32 - bits
  const end = start + count
  for (let n = start; n < end; n++) {
    const solution = String(n)
    if (sha256Words(nonce + solution)[0] >>> shift === 0) return solution
  }
  return null
}

/** Attempts per batch: small enough to yield often, large enough not to thrash. */
export const BATCH = 20000
