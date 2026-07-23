<?php
declare(strict_types=1);

// Optional maintenance-mode switch: touch a file named `.maintenance` next to
// this script to redirect everyone to /maintenance/ instead.
$maintenanceFile = __DIR__ . '/.maintenance';
if (file_exists($maintenanceFile)) {
    header('Location: /maintenance/');
    exit;
}

require_once __DIR__ . '/auth.php';

$user = cs_user();
if (!$user) {
    header('Location: ' . cs_login_url(), true, 302);
    exit;
}

cs_headers();
$dashboard = (string)file_get_contents(CODEXSTATE_DASHBOARD_HTML);
echo str_replace('__CODEXSTATE_CSRF__', json_encode(cs_csrf(), JSON_HEX_TAG | JSON_HEX_AMP), $dashboard);
