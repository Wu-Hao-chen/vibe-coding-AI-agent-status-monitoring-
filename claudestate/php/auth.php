<?php
declare(strict_types=1);

// EDIT ME: This expects an external login gateway that exposes
// auth_current_user(): ?array, returning a truthy array for a logged-in user
// or null otherwise (however you handle that — your own SSO, a simple
// password gate, etc. is entirely up to you; this repo doesn't include one).
//
// SECURITY NOTE: this is the *only* gate in front of the dashboard as shipped
// — whatever auth_current_user() returns, ANY logged-in user gets in, with no
// role/permission check on top. The original private deployment this was
// extracted from also had a role check, a phone/SMS verification step, and a
// TOTP-approval layer here; all removed for this public template because they
// were too specific (tied to one phone number, one Aliyun account, one role
// name) to generalize safely — copy-pasting someone else's example secrets is
// worse than having none. Decide your own risk tolerance before exposing this
// publicly, and add whatever access control you need on top of
// auth_current_user() (a role/permission check, a second factor, an IP
// allowlist, a VPN, etc.).
require_once '/path/to/your/auth-gateway/app.php';
require_once __DIR__ . '/config.php';

function cls_headers(): void {
    header('Content-Type: text/html; charset=utf-8');
    header("Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; frame-src 'none'; connect-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'");
    header('X-Content-Type-Options: nosniff');
    header('X-Frame-Options: DENY');
    header('Referrer-Policy: no-referrer');
    header('Cache-Control: no-store, private');
}

function cls_user(): ?array {
    return auth_current_user();
}

function cls_login_url(): string {
    return '/login/?return=' . rawurlencode('https://' . CLS_DOMAIN . '/claudestate/');
}
