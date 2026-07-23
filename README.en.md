# AI Agent Status Monitoring

*[中文说明](README.md)*

Self-hosted status dashboards for AI coding agents. Each dashboard shows a live traffic-light indicator of the agent's current state (idle / running / awaiting approval), displays token usage, and lets you approve or deny a pending permission request directly from the page.

| Project | Monitors | Backend | Client integration |
|---|---|---|---|
| [`claudestate/`](claudestate) | Claude Code | Node.js + Express (SSE) | Claude Code's native hook system |
| [`hermesstate/`](hermesstate) | Hermes (a desktop AI agent) | Node.js + Express (SSE) | PowerShell scripts polling the process + tailing its log |
| `codexstate/` (coming soon) | Codex-style agents | Plain PHP + local file storage | Integrated by the deployer |

CodexState has already been built internally but is being held back from this release; it's planned to be added in a future update.

## How it works

Each dashboard follows the same shape:

1. **A local script or hook** runs on the machine where the agent itself runs. It watches for lifecycle events (a tool call starting, a tool call finishing, a permission prompt appearing, the agent going idle) and reports them to the backend over HTTP.
2. **A lightweight backend service** (Node.js) receives those reports, keeps a single in-memory state object, and streams state changes to any connected browser over Server-Sent Events.
3. **A PHP gateway** sits in front of the dashboard, deferring to a login check you implement yourself, and only then serves the dashboard page.
4. **The browser dashboard** renders the traffic light, recent activity log, and usage figures, and lets you approve or deny a pending action directly from the page.

### Traffic-light semantics

| State | Meaning |
|---|---|
| 🟢 Green | Idle — no tool call in progress |
| 🟡 Yellow | A tool call is currently running |
| 🔴 Red | The agent is blocked, waiting on a permission decision |

The Node service runs a background watchdog: if a tool call reports no further activity for 5 minutes, yellow automatically reverts to green, so a missed "finished" event can't leave the light stuck forever. Red is deliberately exempt from this — its lifecycle is governed by the timeout on the pending decision itself, and the watchdog must not race ahead of a decision the user is still in the middle of making.

### Why Server-Sent Events, not WebSockets

The Node services push updates over SSE (`GET /events`) rather than WebSockets — a status dashboard only ever needs one-way updates, which SSE handles fine, and the browser's `EventSource` API reconnects automatically on its own. If running a persistent Node process isn't convenient for your backend, you can instead have the frontend poll a plain REST endpoint on an interval; the tradeoff is slightly worse latency in exchange for a simpler, stateless backend.

## Security model

**Neither dashboard ships with built-in authentication.** The only gate in front of the dashboard is a function you implement yourself, `auth_current_user()`, which the PHP gateway calls to decide whether the current request is logged in. Beyond that single check, this repository places no further restriction on who can view the dashboard or approve/deny a pending request — the Node service's `/events` and `/decision/:id` endpoints do not independently verify the caller's identity.

This is a deliberate design decision, not an oversight: this repository is a sanitized reference implementation extracted from a private deployment, and the additional access-control layers that deployment used were tightly coupled to its specific environment in ways that could not be safely carried over into a general-purpose template. Shipping a version that looked complete but couldn't actually be relied on would have been worse than being explicit about what's missing.

**Before deploying this publicly, assess this risk for your own use case and add whatever access control you need** — for example, a role or permission check inside `auth_current_user()`, a second factor, an IP allowlist, or placing the whole deployment behind a VPN. Every place in the code where such a check would go is marked with a comment.

## Repository layout

Every sub-project directory has its own `README.md` with complete deployment steps. Each also ships an `.env.example` / `config.example.php` listing every configuration value it needs, and inline comments marking anything environment-specific that you'll need to replace with your own values.

```
claudestate/
  server.js            Node backend: hook ingestion, SSE stream, decision endpoint
  public/index.html     Dashboard frontend
  php/                  Login gateway + dashboard shell serving
  hooks/                Scripts to install on the machine running Claude Code
  .env.example

hermesstate/
  (same layout as claudestate/, with process-polling + log-tailing in place
  of native hooks for client integration)
```

## Limitations

- **Single global state.** Each backend keeps exactly one state object, not one per session. If multiple agent sessions report to the same deployment at once, the dashboard reflects whichever one reported most recently — it does not distinguish between them.
- **Not a turnkey product.** This is a reference implementation, not a polished installable package. You'll need to implement your own login gateway, and `hermesstate`'s log-parsing regex is written against one specific agent version — expect to adapt it for a different agent or a newer release.

## About this project

This project was designed and generated by the author with the assistance of AI, based on a private deployment the author originally built. It has been extracted, sanitized, and published here as a general-purpose reference implementation.

This reference implementation comes with no guarantee of security or reliability. Please evaluate it critically, adapt it to your own environment, and harden it as needed before relying on it. If you have questions, or discover a significant issue, please get in touch.
