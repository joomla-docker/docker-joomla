<?php
// Check PHP's effective runtime, independently of the generated INI contents.
declare(strict_types=1);

function requireCondition(bool $condition, string $message): void
{
    if (!$condition) {
        fwrite(STDERR, $message . "\n");
        exit(1);
    }
}

if (($argv[1] ?? '') === 'snapshot') {
    $settings = ini_get_all(null, false);
    ksort($settings);
    echo json_encode($settings, JSON_THROW_ON_ERROR), "\n";
    exit(0);
}

foreach (['expose_php', 'allow_url_include', 'session.upload_progress.enabled'] as $setting) {
    $value = ini_get($setting);
    requireCondition($value !== false, "$setting must be available");
    requireCondition(!filter_var($value, FILTER_VALIDATE_BOOLEAN), "$setting must be off");
}
foreach (['session.cookie_httponly', 'session.cookie_secure', 'session.use_strict_mode',
    'session.use_cookies', 'session.use_only_cookies', 'zend.exception_ignore_args'] as $setting) {
    requireCondition(filter_var(ini_get($setting), FILTER_VALIDATE_BOOLEAN), "$setting must be on");
}
requireCondition(ini_get('session.cookie_samesite') === 'Lax', 'SameSite must be Lax');
