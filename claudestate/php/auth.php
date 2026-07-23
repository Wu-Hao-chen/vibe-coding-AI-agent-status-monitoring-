<?php
declare(strict_types=1);

// EDIT ME: This expects an external login gateway that exposes
// auth_current_user(): ?array, returning at least ['id' => int, 'role' => string]
// for the logged-in admin (however you handle that — your own SSO, a simple
// password gate, etc. is entirely up to you; this repo doesn't include one).
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
    $user = auth_current_user();
    if (!$user || ($user['role'] ?? '') !== 'super_admin') return null;
    return $user;
}

function cls_login_url(): string {
    return '/login/?return=' . rawurlencode('https://' . CLS_DOMAIN . '/claudestate/');
}

function cls_b64u(string $v): string {
    return rtrim(strtr(base64_encode($v), '+/', '-_'), '=');
}

// The Node server (server.js) is a separate process on a different port, so
// it can't read this PHP app's session — instead we hand it a short-lived,
// HMAC-signed cookie it can verify on its own. Re-issued on every page load
// (see index.php), so it's really just "were you allowed into index.php
// recently", not a separate credential of its own.
function cls_set_trusted(array $user): void {
    $payload = cls_b64u(json_encode([
        'uid'   => (int)$user['id'],
        'exp'   => time() + CLS_TRUST_TTL,
        'ua'    => hash('sha256', $_SERVER['HTTP_USER_AGENT'] ?? ''),
        'nonce' => bin2hex(random_bytes(12)),
    ], JSON_UNESCAPED_SLASHES));
    $value = $payload . '.' . hash_hmac('sha256', $payload, CLS_COOKIE_KEY);
    setcookie('CLAUDESTATE_TRUST', $value, [
        'expires' => time() + CLS_TRUST_TTL,
        'path'    => '/claudestate/',
        'secure'  => true, 'httponly' => true, 'samesite' => 'Strict',
    ]);
}
