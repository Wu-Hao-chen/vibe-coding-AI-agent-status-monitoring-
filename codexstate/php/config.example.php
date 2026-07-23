<?php
declare(strict_types=1);

// Copy this file to config.php (which is .gitignore'd) and fill in your own
// values. Never commit the real config.php.

// Your domain, no scheme, no trailing slash — e.g. "example.com"
const CODEXSTATE_DOMAIN = 'YOUR-DOMAIN';

// Bearer token your Codex-side agent/script sends to authenticate its own
// status updates (see api.php's require_token()). Generate with
// `openssl rand -hex 32`.
const CODEXSTATE_AGENT_TOKEN = 'REPLACE_ME';

// Absolute path to dashboard.html (the dashboard shell) — see ../dashboard.html.
const CODEXSTATE_DASHBOARD_HTML = __DIR__ . '/dashboard.html';

const CODEXSTATE_DATA_DIR     = __DIR__ . '/data';
const CODEXSTATE_FILE         = CODEXSTATE_DATA_DIR . '/state.json';
const CODEXSTATE_COMMAND_FILE = CODEXSTATE_DATA_DIR . '/command.json';
