<?php
declare(strict_types=1);

require_once __DIR__ . '/auth.php';

$user = hms_user();
if (!$user) {
    header('Location: ' . hms_login_url(), true, 302);
    exit;
}

// Re-issue the signed trust cookie on every load so the Node backend (a
// separate process/port) can verify /events requests from this browser.
hms_set_trusted($user);

hms_headers();
$html = @file_get_contents(HMS_DASHBOARD_HTML);
if ($html === false) { http_response_code(503); echo 'Dashboard unavailable'; exit; }
echo $html;
