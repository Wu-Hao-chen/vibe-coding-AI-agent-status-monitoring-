<?php
declare(strict_types=1);

// Copy this file to config.php (which is .gitignore'd) and fill in your own
// values. Never commit the real config.php.

// Your domain, no scheme, no trailing slash — e.g. "example.com"
const CLS_DOMAIN = 'YOUR-DOMAIN';

// Random 32+ byte hex string, e.g. `openssl rand -hex 32`.
// Must match CLS_COOKIE_KEY in the Node server's .env (see ../.env.example).
const CLS_COOKIE_KEY = 'REPLACE_ME';

// Absolute path to the Node server's public/index.html (the dashboard shell) —
// see ../server.js. This PHP layer reads and serves that file directly once
// the visitor is verified.
const CLS_DASHBOARD_HTML = '/path/to/claudestate/public/index.html';

const CLS_TRUST_TTL = 30 * 86400;
