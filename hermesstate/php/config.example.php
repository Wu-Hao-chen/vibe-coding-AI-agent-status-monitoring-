<?php
declare(strict_types=1);

// Copy this file to config.php (which is .gitignore'd) and fill in your own
// values. Never commit the real config.php.

// Your domain, no scheme, no trailing slash — e.g. "example.com"
const HMS_DOMAIN = 'YOUR-DOMAIN';

// Random 32+ byte hex string, e.g. `openssl rand -hex 32`.
// Must match HMS_COOKIE_KEY in the Node server's .env (see ../.env.example).
const HMS_COOKIE_KEY = 'REPLACE_ME';

// Base32 secret for the TOTP second factor used when approving/denying a
// pending permission request from the dashboard (checked by server.js, not
// this PHP file — see auth.php's comment above hms_verify_totp()).
// Generate one with any TOTP library, or
// `python3 -c "import pyotp; print(pyotp.random_base32())"`.
const HMS_TOTP_SECRET = 'REPLACE_ME';

// Absolute path to the Node server's public/index.html (the dashboard shell) —
// see ../server.js. This PHP layer reads and serves that file directly once
// the visitor is verified.
const HMS_DASHBOARD_HTML = '/path/to/hermesstate/public/index.html';

const HMS_TRUST_TTL = 30 * 86400;
