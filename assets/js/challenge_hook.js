/**
 * ChallengeHook — solves the registration proof-of-work challenge (P5-D1)
 * and pushes the answer to `RegisterLive`.
 *
 * Mounted on a hidden element carrying `data-nonce` and `data-bits`. It starts
 * as soon as the page is connected, so by the time somebody has typed a
 * username and a password the answer is usually already back; a submit that
 * arrives first is held by the server, not by this hook, and completed when the
 * answer lands. The submit button is never disabled — a control that does
 * nothing and says nothing is how "the site is broken" starts.
 *
 * Registration is the one page a visitor cannot route around, so this has to
 * survive the browser misbehaving:
 *
 *   - **No `Worker`, or the worker fails to start** (a 404 during a deploy, a
 *     policy that forbids it) → the same solver runs on the main thread in
 *     small batches with a `setTimeout` between them, so the page stays
 *     responsive. Slower, and never a dead end.
 *   - **A fresh challenge** (the server re-issues one after every attempt)
 *     arrives as a `challenge` event; the running search is abandoned and a
 *     new one started. Each run carries a token, so an answer to a challenge
 *     that is no longer current is never pushed.
 *   - **Nothing reaches the console.** `features/js_errors_test.exs` fails the
 *     build on `console.error` and on an unhandled rejection, and a worker
 *     error event is reported unless it is handled here.
 */
import { solveBatch, BATCH } from "./challenge_solver"

const ChallengeHook = {
  mounted() {
    this.handleEvent("challenge", ({ nonce, bits }) => this.solve(nonce, bits))
    this.solve(this.el.dataset.nonce, parseInt(this.el.dataset.bits, 10))
  },

  destroyed() {
    this.stop()
  },

  stop() {
    this.run = null
    if (this.worker) {
      this.worker.terminate()
      this.worker = null
    }
  },

  solve(nonce, bits) {
    this.stop()
    if (typeof nonce !== "string" || nonce === "" || !Number.isInteger(bits) || bits <= 0) return

    const run = {}
    this.run = run

    const done = (solution, via) => {
      if (this.run !== run) return
      this.stop()
      // Which path answered. A broken worker would otherwise be invisible —
      // the main-thread fallback still registers people, only slower — so the
      // browser test asserts on this, and it is there to read in devtools.
      //
      // Written into a child, not onto this element: the container is
      // `phx-update="ignore"`, and LiveView still re-syncs an ignored
      // element's own `data-*` attributes from the server on every patch, so a
      // `data-` attribute set here would vanish as soon as the visitor typed.
      // An ignored element's children are never touched.
      let marker = this.el.querySelector(".register-challenge-via")
      if (!marker) {
        marker = document.createElement("span")
        marker.className = "register-challenge-via"
        this.el.appendChild(marker)
      }
      marker.dataset.via = via
      this.pushEvent("challenge_solved", { nonce, solution })
    }

    let worker
    try {
      worker = new Worker("/challenge_worker.js")
    } catch (_e) {
      this.onMainThread(nonce, bits, run, done)
      return
    }

    this.worker = worker
    worker.onmessage = (event) => {
      const data = event.data || {}
      if (data.nonce === nonce && typeof data.solution === "string") done(data.solution, "worker")
    }
    worker.onerror = (event) => {
      // Handled, so it is not reported as an uncaught error.
      if (event && typeof event.preventDefault === "function") event.preventDefault()
      if (this.run !== run) return
      worker.terminate()
      this.worker = null
      this.onMainThread(nonce, bits, run, done)
    }
    worker.postMessage({ nonce, bits })
  },

  onMainThread(nonce, bits, run, done) {
    let start = 0
    const step = () => {
      if (this.run !== run) return
      const solution = solveBatch(nonce, bits, start, BATCH)
      if (solution !== null) {
        done(solution, "main-thread")
        return
      }
      start += BATCH
      setTimeout(step, 0)
    }
    setTimeout(step, 0)
  },
}

export default ChallengeHook
