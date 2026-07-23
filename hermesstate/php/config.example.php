<?php
declare(strict_types=1);

// Copy this file to config.php (which is .gitignore'd) and fill in your own
// values. Never commit the real config.php.

// Your domain, no scheme, no trailing slash — e.g. "example.com"
const HMS_DOMAIN = 'YOUR-DOMAIN';

// Absolute path to the Node server's public/index.html (the dashboard shell) —
// see ../server.js. This PHP layer reads and serves that file directly once
// the visitor is verified.
const HMS_DASHBOARD_HTML = '/path/to/hermesstate/public/index.html';
