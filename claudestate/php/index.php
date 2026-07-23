<?php
declare(strict_types=1);

require_once __DIR__ . '/auth.php';

$user = cls_user();
if (!$user) {
    header('Location: ' . cls_login_url(), true, 302);
    exit;
}

cls_headers();
$html = @file_get_contents(CLS_DASHBOARD_HTML);
if ($html === false) { http_response_code(503); echo 'Dashboard unavailable'; exit; }
echo $html;
