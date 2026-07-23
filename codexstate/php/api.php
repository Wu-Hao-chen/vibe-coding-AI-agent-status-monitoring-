<?php
declare(strict_types=1);

require_once __DIR__ . '/auth.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$action = (string)($_GET['action'] ?? 'status');

if ($method === 'GET' && $action === 'status') {
    require_dashboard_access();
    echo_json(public_state(load_json(CODEXSTATE_FILE, default_state())));
    exit;
}

if ($method === 'GET' && $action === 'command') {
    require_token(CODEXSTATE_AGENT_TOKEN);
    echo_json(['ok' => true, 'command' => load_json(CODEXSTATE_COMMAND_FILE, null)]);
    exit;
}

if ($method !== 'POST') {
    fail(405, 'method_not_allowed');
}

$op = (string)($_POST['op'] ?? 'update');
if ($op === 'decision') {
    require_dashboard_access();
    if (!cs_verify_csrf($_POST['csrf'] ?? null)) fail(403, 'csrf_failed');
    $decision = (string)($_POST['decision'] ?? '');
    if (!in_array($decision, ['accept', 'decline'], true)) fail(422, 'invalid_decision');
    if ($decision === 'accept' && !cs_verify_totp(trim((string)($_POST['totp'] ?? '')), true)) fail(403, 'invalid_totp');
    queue_decision();
    exit;
}

require_token(CODEXSTATE_AGENT_TOKEN);
if ($op === 'ack') {
    acknowledge_command();
    exit;
}
if ($op !== 'update') {
    fail(422, 'invalid_operation');
}

$state = (string)($_POST['state'] ?? '');
if (!in_array($state, ['waiting', 'running', 'done'], true)) {
    fail(422, 'invalid_state');
}

$payload = load_json(CODEXSTATE_FILE, default_state());
$payload['state'] = $state;
$payload['message'] = limit_text(trim((string)($_POST['message'] ?? '')), 160);
$payload['source'] = limit_text(trim((string)($_POST['source'] ?? 'agent')), 40);
$payload['updatedAt'] = gmdate('c');

foreach (['tokensRemaining', 'tokensUsed', 'contextWindow'] as $field) {
    if (isset($_POST[$field]) && $_POST[$field] !== '') {
        $payload[$field] = max(0, (int)$_POST[$field]);
    }
}

if (array_key_exists('rateLimits', $_POST)) {
    $rateLimits = json_decode((string)$_POST['rateLimits'], true);
    $payload['rateLimits'] = is_array($rateLimits) ? sanitize_rate_limits($rateLimits) : null;
}

if (array_key_exists('tokenUsage', $_POST)) {
    $tokenUsage = json_decode((string)$_POST['tokenUsage'], true);
    $payload['tokenUsage'] = is_array($tokenUsage) ? sanitize_token_usage_payload($tokenUsage) : null;
}

if (array_key_exists('approval', $_POST)) {
    $approval = json_decode((string)$_POST['approval'], true);
    $payload['approval'] = is_array($approval) ? $approval : null;
}
if ((string)($_POST['clearApproval'] ?? '') === '1') {
    $payload['approval'] = null;
}

save_json(CODEXSTATE_FILE, $payload);
echo_json(['ok' => true, 'state' => public_state($payload)]);

function queue_decision(): void
{
    $approvalId = trim((string)($_POST['approvalId'] ?? ''));
    $decision = (string)($_POST['decision'] ?? '');
    if (!in_array($decision, ['accept', 'decline'], true)) {
        fail(422, 'invalid_decision');
    }

    $state = load_json(CODEXSTATE_FILE, default_state());
    $approval = $state['approval'] ?? null;
    if (!is_array($approval) || !hash_equals((string)($approval['id'] ?? ''), $approvalId)) {
        fail(409, 'stale_approval');
    }
    if (($approval['status'] ?? 'pending') !== 'pending' || empty($approval['actionable'])) {
        fail(409, 'approval_not_actionable');
    }

    $command = [
        'id' => bin2hex(random_bytes(16)),
        'approvalId' => $approvalId,
        'decision' => $decision,
        'route' => $approval['route'] ?? null,
        'createdAt' => gmdate('c'),
    ];
    if (!is_array($command['route'])) {
        fail(409, 'approval_route_missing');
    }

    save_json(CODEXSTATE_COMMAND_FILE, $command);
    $state['approval']['status'] = 'queued';
    $state['approval']['queuedDecision'] = $decision;
    $state['updatedAt'] = gmdate('c');
    save_json(CODEXSTATE_FILE, $state);
    echo_json(['ok' => true, 'commandId' => $command['id']]);
}

function acknowledge_command(): void
{
    $commandId = trim((string)($_POST['commandId'] ?? ''));
    $command = load_json(CODEXSTATE_COMMAND_FILE, null);
    if (!is_array($command) || !hash_equals((string)($command['id'] ?? ''), $commandId)) {
        fail(409, 'stale_command');
    }

    $outcome = (string)($_POST['outcome'] ?? 'failed');
    @unlink(CODEXSTATE_COMMAND_FILE);
    $state = load_json(CODEXSTATE_FILE, default_state());
    if (is_array($state['approval'] ?? null) && ($state['approval']['id'] ?? '') === ($command['approvalId'] ?? '')) {
        $state['approval']['status'] = $outcome === 'ok' ? 'resolved' : 'failed';
        $state['approval']['result'] = limit_text((string)($_POST['result'] ?? ''), 160);
    }
    $state['updatedAt'] = gmdate('c');
    save_json(CODEXSTATE_FILE, $state);
    echo_json(['ok' => true]);
}

function require_token(string $expected, string $field = 'token'): void
{
    $actual = $_POST[$field] ?? $_GET[$field] ?? ($_SERVER['HTTP_X_CODEXSTATE_TOKEN'] ?? '');
    if (!hash_equals($expected, (string)$actual)) {
        fail(403, 'forbidden');
    }
}

function require_dashboard_access(): void
{
    if (!cs_user()) fail(401, 'authentication_required');
}

function public_state(array $state): array
{
    if (is_array($state['approval'] ?? null)) {
        unset($state['approval']['route']);
    }
    return $state;
}

function default_state(): array
{
    return [
        'state' => 'done', 'message' => '', 'source' => 'default', 'updatedAt' => '',
        'tokensRemaining' => 0, 'tokensUsed' => 0, 'contextWindow' => 0, 'rateLimits' => null, 'tokenUsage' => null, 'approval' => null,
    ];
}

function sanitize_token_usage_payload(array $value): array
{
    return [
        'total' => sanitize_token_usage($value['total'] ?? null),
        'last' => sanitize_token_usage($value['last'] ?? null),
    ];
}

function sanitize_token_usage(mixed $value): ?array
{
    if (!is_array($value)) return null;
    return [
        'inputTokens' => max(0, (int)($value['inputTokens'] ?? 0)),
        'cachedInputTokens' => max(0, (int)($value['cachedInputTokens'] ?? 0)),
        'outputTokens' => max(0, (int)($value['outputTokens'] ?? 0)),
        'reasoningOutputTokens' => max(0, (int)($value['reasoningOutputTokens'] ?? 0)),
        'totalTokens' => max(0, (int)($value['totalTokens'] ?? 0)),
    ];
}

function sanitize_rate_limits(array $value): array
{
    return [
        'limitId' => limit_text((string)($value['limitId'] ?? ''), 40),
        'fiveHour' => sanitize_rate_window($value['fiveHour'] ?? null),
        'weekly' => sanitize_rate_window($value['weekly'] ?? null),
    ];
}

function sanitize_rate_window(mixed $value): ?array
{
    if (!is_array($value)) return null;
    $used = max(0.0, min(100.0, (float)($value['usedPercent'] ?? 0)));
    return [
        'usedPercent' => $used,
        'remainingPercent' => max(0.0, min(100.0, (float)($value['remainingPercent'] ?? (100.0 - $used)))),
        'windowMinutes' => max(0, (int)($value['windowMinutes'] ?? 0)),
        'resetsAt' => max(0, (int)($value['resetsAt'] ?? 0)),
    ];
}

function load_json(string $path, mixed $fallback): mixed
{
    if (!is_file($path)) return $fallback;
    $value = json_decode((string)file_get_contents($path), true);
    return $value === null ? $fallback : $value;
}

function save_json(string $path, array $value): void
{
    $json = json_encode($value, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT);
    $tmp = $path . '.tmp';
    if ($json === false || file_put_contents($tmp, $json . PHP_EOL, LOCK_EX) === false || !rename($tmp, $path)) {
        fail(500, 'write_failed');
    }
}

function echo_json(mixed $value): void
{
    echo json_encode($value, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
}

function fail(int $status, string $error): never
{
    http_response_code($status);
    echo_json(['ok' => false, 'error' => $error]);
    exit;
}

function limit_text(string $value, int $length): string
{
    return function_exists('mb_substr') ? mb_substr($value, 0, $length, 'UTF-8') : substr($value, 0, $length * 3);
}
