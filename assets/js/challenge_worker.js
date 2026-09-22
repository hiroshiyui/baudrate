/**
 * Solves the registration proof-of-work challenge off the main thread
 * (P5-D1). Loaded as `new Worker("/challenge_worker.js")` — a same-origin
 * file, because the content security policy's `worker-src` is `'self'` and
 * does not admit a `blob:` worker; and a bare literal path, never `~p`,
 * for the reason ADR 0059 gives the service worker: `phx.digest` keeps the
 * undigested original, and a digest-stamped name would change on every
 * deploy.
 *
 * One message in, one message out. A loop with no yield is right here: this
 * thread has nothing else to do, and a fresh challenge is handled by the
 * hook terminating this worker and starting another rather than by
 * interrupting this one.
 */
import { solveBatch, BATCH } from "./challenge_solver"

self.onmessage = (event) => {
  const { nonce, bits } = event.data || {}
  if (typeof nonce !== "string" || !Number.isInteger(bits) || bits <= 0) return

  for (let start = 0; ; start += BATCH) {
    const solution = solveBatch(nonce, bits, start, BATCH)
    if (solution !== null) {
      self.postMessage({ nonce, solution })
      return
    }
  }
}
