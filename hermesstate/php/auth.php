<?php
declare(strict_types=1);

// EDIT ME: This expects an external login gateway that exposes
// auth_current_user(): ?array, returning at least ['id' => int, 'role' => string]
// for the logged-in admin (however you handle that — your own SSO, a simple
// password gate, etc. is entirely up to you; this repo doesn't include one).
require_once '/path/to/your/auth-gateway/app.php';
require_once __DIR__ . '/config.php';

function hms_headers(): void {
    header('Content-Type: text/html; charset=utf-8');
    header("Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; frame-src 'none'; connect-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'");
    header('X-Content-Type-Options: nosniff');
    header('X-Frame-Options: DENY');
    header('Referrer-Policy: no-referrer');
    header('Cache-Control: no-store, private');
}

function hms_user(): ?array {
    $user = auth_current_user();
    if (!$user || ($user['role'] ?? '') !== 'super_admin') return null;
    return $user;
}

function hms_login_url(): string {
    return '/login/?return=' . rawurlencode('https://' . HMS_DOMAIN . '/hermesstate/');
}

function hms_b64u(string $value): string {
    return rtrim(strtr(base64_encode($value), '+/', '-_'), '=');
}

// The Node server (server.js) is a separate process on a different port, so
// it can't read this PHP app's session — instead we hand it a short-lived,
// HMAC-signed cookie it can verify on its own. Re-issued on every page load
// (see index.php), so it's really just "were you allowed into index.php
// recently", not a separate credential of its own.
function hms_set_trusted(array $user): void {
    $payload = hms_b64u(json_encode([
        'uid'   => (int)$user['id'],
        'exp'   => time() + HMS_TRUST_TTL,
        'ua'    => hash('sha256', $_SERVER['HTTP_USER_AGENT'] ?? ''),
        'nonce' => bin2hex(random_bytes(12)),
    ], JSON_UNESCAPED_SLASHES));
    $value = $payload . '.' . hash_hmac('sha256', $payload, HMS_COOKIE_KEY);
    setcookie('HERMESSTATE_TRUST', $value, [
        'expires' => time() + HMS_TRUST_TTL, 'path' => '/hermesstate/',
        'secure'  => true, 'httponly' => true, 'samesite' => 'Strict',
    ]);
}

// TOTP below is used for approving/denying a pending permission request from
// the dashboard (see server.js's /hook/permission + /decision/:id), NOT for
// login — it's a second factor checked by the Node server itself. Kept here
// as a reference implementation in case you want to move that check into PHP
// instead; server.js's own verifyTotp() (reading .totp_secret directly) is
// what's actually wired up by default.
function hms_base32_decode(string $secret): string
{
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    $bits = '';
    foreach (str_split(strtoupper($secret)) as $char) {
        $index = strpos($alphabet, $char);
        if ($index === false) continue;
        $bits .= str_pad(decbin($index), 5, '0', STR_PAD_LEFT);
    }
    $output = '';
    for ($i = 0; $i + 8 <= strlen($bits); $i += 8) $output .= chr(bindec(substr($bits, $i, 8)));
    return $output;
}

function hms_totp_for_counter(int $counter): string
{
    $high = intdiv($counter, 0x100000000);
    $low  = $counter % 0x100000000;
    $hash = hash_hmac('sha1', pack('NN', $high, $low), hms_base32_decode(HMS_TOTP_SECRET), true);
    $offset = ord($hash[19]) & 0x0f;
    $value  = unpack('N', substr($hash, $offset, 4))[1] & 0x7fffffff;
    return str_pad((string)($value % 1000000), 6, '0', STR_PAD_LEFT);
}

function hms_verify_totp(string $code): bool
{
    if (!preg_match('/^\d{6}$/', $code)) return false;
    $current = intdiv(time(), 30);
    for ($counter = $current - 1; $counter <= $current + 1; $counter++) {
        if (hash_equals(hms_totp_for_counter($counter), $code)) return true;
    }
    return false;
}
