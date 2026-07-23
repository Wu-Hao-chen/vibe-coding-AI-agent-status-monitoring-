<?php
declare(strict_types=1);

// Copy this file to config.php (which is .gitignore'd) and fill in your own
// values. Never commit the real config.php.

// Your domain, no scheme, no trailing slash — e.g. "example.com"
const CODEXSTATE_DOMAIN = 'YOUR-DOMAIN';

// Only this username (from your login gateway's auth_current_user()) is
// allowed in, even if they're otherwise a super_admin.
const CODEXSTATE_ALLOWED_USERNAME = 'REPLACE_ME';

// Bearer token your Codex-side agent/script sends to authenticate its own
// status updates (see api.php's require_token()). Generate with
// `openssl rand -hex 32`.
const CODEXSTATE_AGENT_TOKEN = 'REPLACE_ME';

// Base32 secret for the TOTP second factor used when approving/denying a
// pending action from the dashboard. Add it to your authenticator app
// manually — it's not displayed anywhere in the UI.
const CODEXSTATE_TOTP_SECRET = 'REPLACE_ME';

// Absolute path to dashboard.html (the dashboard shell) — see ../dashboard.html.
const CODEXSTATE_DASHBOARD_HTML = __DIR__ . '/dashboard.html';

const CODEXSTATE_DATA_DIR         = __DIR__ . '/data';
const CODEXSTATE_FILE             = CODEXSTATE_DATA_DIR . '/state.json';
const CODEXSTATE_COMMAND_FILE     = CODEXSTATE_DATA_DIR . '/command.json';
const CODEXSTATE_TOTP_COUNTER_FILE = CODEXSTATE_DATA_DIR . '/totp-counter';
