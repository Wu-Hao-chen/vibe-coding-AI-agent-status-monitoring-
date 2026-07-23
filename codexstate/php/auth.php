<?php
declare(strict_types=1);

// EDIT ME: This expects an external login gateway that exposes
// auth_current_user(): ?array, returning a truthy array for a logged-in user
// or null otherwise (however you handle that — your own SSO, a simple
// password gate, etc. is entirely up to you; this repo doesn't include one).
//
// SECURITY NOTE: this is the *only* gate in front of the dashboard as shipped
// — whatever auth_current_user() returns, ANY logged-in user gets in, with no
// role/username/permission check on top. The original private deployment
// this was extracted from also had a hardcoded username allowlist, a
// phone/SMS verification step, and a TOTP-enrollment layer here; all removed
// for this public template because they were too specific (tied to one
// username, one phone number, one Aliyun account) to generalize safely —
// copy-pasting someone else's example secrets is worse than having none.
// Decide your own risk tolerance before exposing this publicly, and add
// whatever access control you need on top of auth_current_user() (a
// role/username check, a second factor, an IP allowlist, a VPN, etc.).
require_once '/path/to/your/auth-gateway/app.php';
require_once __DIR__ . '/config.php';

function cs_headers(): void
{
    header('Content-Type: text/html; charset=utf-8');
    header("Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; frame-src 'none'; connect-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'");
    header('X-Content-Type-Options: nosniff');
    header('X-Frame-Options: DENY');
    header('Referrer-Policy: no-referrer');
    header('Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()');
    header('Cache-Control: no-store, private');
}

function cs_user(): ?array
{
    return auth_current_user();
}

function cs_login_url(): string
{
    return '/login/?return=' . rawurlencode('https://' . CODEXSTATE_DOMAIN . '/codexstate/');
}

function cs_start_session(): void
{
    if (session_status() === PHP_SESSION_ACTIVE) return;
    session_name('CODEXSTATE_UI');
    session_set_cookie_params([
        'lifetime' => 1800, 'path' => '/codexstate/', 'secure' => true,
        'httponly' => true, 'samesite' => 'Strict',
    ]);
    session_start();
}

// Just CSRF protection for the dashboard's own approve/decline action — not
// an identity check, kept regardless since it's a real state-changing POST
// from the browser.
function cs_csrf(): string
{
    cs_start_session();
    if (empty($_SESSION['csrf'])) $_SESSION['csrf'] = bin2hex(random_bytes(24));
    return (string)$_SESSION['csrf'];
}

function cs_verify_csrf(?string $token): bool
{
    return is_string($token) && hash_equals(cs_csrf(), $token);
}
