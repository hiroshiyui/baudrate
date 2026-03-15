# Door Applications Development Guide

This document outlines the architectural patterns and security mandates for implementing "Door Apps"—rich, interactive, and often graphical applications that extend the Baudrate BBS. 

Baudrate prioritizes information security and federated interaction. "Door Apps" are not limited to entertainment; they serve as a general-purpose extension platform for graphical tools, interactive data visualizations, and multi-user utilities that respect these principles.

## 1. Core Architecture: The "Socket" Pattern

Instead of legacy raw executables, Baudrate Door Apps use a decoupled architecture where Elixir manages state and the frontend handles high-fidelity rendering.

### Plug-in System
- **WASM Isolation:** Use WebAssembly (via NIFs like `wasmer-elixir`) to run server-side App logic. This provides near-native performance with absolute memory sandboxing.
- **Elixir Behaviours:** Define a standard interface for Door App plugins:
  ```elixir
  defmodule Baudrate.Doors.Plugin do
    @callback init(user_id :: integer(), state :: map()) :: {:ok, map()}
    @callback handle_input(input :: String.t(), state :: map()) :: {:reply, String.t(), map()}
  end
  ```
- **Rich Interface rendering:** While text-based interfaces can use ANSI sequences, Door Apps typically utilize Canvas, WebGL, or WebGPU for modern, high-fidelity user experiences.

## 2. Identification & Session Handoff

In a federated context, Apps must identify users securely without direct access to credentials.

- **App Tokens:** Generate short-lived (60s), single-use `door_token` values stored in the database/Redis.
- **Profile Resolution:** The App requests user metadata via the `Baudrate.Auth` facade using the token.
- **Federated Identity:** Always use the canonical `ap_id` or `actor_uri`. This allows App actions to be federated back to the user's home instance (e.g., publishing a document or sharing a visualization).

## 3. Security Mandates (Defense in Depth)

Door Apps are untrusted code and must be strictly isolated.

- **Process Sandboxing:** Every App instance must run in its own Erlang process. Use `Process.monitor/1` to prevent a crashing App from impacting the main Phoenix node.
- **Restricted Persistence:** No direct access to `Baudrate.Repo`. Use a restricted `Baudrate.Doors.Storage` API that utilizes a separate PostgreSQL schema or JSONB "data" columns for App-specific state.
- **Network Air-gapping:** If executing external binaries, use Linux namespaces/containers to disable all network access, preventing SSRF or data exfiltration.
- **Resource Quotas:** Enforce strict memory and CPU limits per process to mitigate DoS attacks.

## 4. WASM Graphical Applications

For high-performance graphical Apps (WebGL/WebGPU/Canvas), use a "Canvas Bridge" architecture.

### Implementation: `DoorHook`
Utilize a Phoenix LiveView Hook in `assets/js/app.js` to mount the WASM runtime:

```javascript
Hooks.WasmDoor = {
  mounted() {
    const canvas = this.el.querySelector("canvas");
    const token = this.el.dataset.doorToken;

    import("/doors/app_engine.wasm").then(wasm => {
      wasm.start_app(canvas, token, (event) => {
        this.pushEvent("app_action", event);
      });
    });

    this.handleEvent("server_update", (payload) => {
      window.wasm_api.update_state(payload);
    });
  }
};
```

### Graphical Security & Isolation
- **CSP Headers:** Update Content Security Policy to allow `wasm-unsafe-eval` for specific paths.
- **Client Validation:** **Never trust the WASM client.** The WASM app is a "dumb terminal" for graphics and UI interaction. The Elixir backend MUST validate every state change or data submission.
- **Asset Sandboxing:** Serve UI assets, textures, and fonts from scoped paths (e.g., `/priv/static/doors/`) with `no-referrer` policies.

## 5. Federated Integration

Bridge the gap between siloed Apps and the Baudrate "Public Information Hub" via existing contexts:

- **Content Facade:** Use `Baudrate.Content.Articles` to allow Apps to post bulletins, results, or shared content to specific Boards.
- **Notifications:** Use `Baudrate.Notification` for collaboration alerts or turn-based interaction.
- **ActivityPub:** Generate `Create`, `Update`, or `Announce` activities for significant App events to propagate them across the fediverse.
