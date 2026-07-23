<?php
declare(strict_types=1);

// EDIT ME: This expects an external login gateway that exposes
// auth_current_user(): ?array, returning at least
// ['id' => int, 'username' => string, 'role' => string] for the logged-in admin
// (however you handle that — your own SSO, a simple password gate, etc. is
// entirely up to you; this repo doesn't include one).
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
    $user = auth_current_user();
    if (!$user || strtolower((string)$user['username']) !== strtolower(CODEXSTATE_ALLOWED_USERNAME) || ($user['role'] ?? '') !== 'super_admin') {
        return null;
    }
    return $user;
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
// part of "verification", kept regardless since it's a real state-changing
// POST from the browser.
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

// TOTP is used for approving/denying a pending action from the dashboard
// (see api.php's op === 'decision'), NOT for login — cs_user() alone gates
// the dashboard. Add CODEXSTATE_TOTP_SECRET to your authenticator app
// manually (it's not displayed anywhere in the UI).
function cs_base32_decode(string $secret): string
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

function cs_totp_for_counter(int $counter): string
{
    $high = intdiv($counter, 0x100000000);
    $low = $counter % 0x100000000;
    $hash = hash_hmac('sha1', pack('NN', $high, $low), cs_base32_decode(CODEXSTATE_TOTP_SECRET), true);
    $offset = ord($hash[19]) & 0x0f;
    $value = unpack('N', substr($hash, $offset, 4))[1] & 0x7fffffff;
    return str_pad((string)($value % 1000000), 6, '0', STR_PAD_LEFT);
}

// $consume prevents the same code being replayed twice within its validity
// window — pass true when this check authorizes a real action (like here,
// approving a pending command).
function cs_verify_totp(string $code, bool $consume = false): bool
{
    if (!preg_match('/^\d{6}$/', $code)) return false;
    $current = intdiv(time(), 30);
    for ($counter = $current - 1; $counter <= $current + 1; $counter++) {
        if (!hash_equals(cs_totp_for_counter($counter), $code)) continue;
        if (!$consume) return true;
        $fh = fopen(CODEXSTATE_TOTP_COUNTER_FILE, 'c+');
        if (!$fh) return false;
        flock($fh, LOCK_EX);
        $last = (int)trim(stream_get_contents($fh));
        if ($counter <= $last) { flock($fh, LOCK_UN); fclose($fh); return false; }
        ftruncate($fh, 0); rewind($fh); fwrite($fh, (string)$counter); fflush($fh);
        flock($fh, LOCK_UN); fclose($fh);
        return true;
    }
    return false;
}
