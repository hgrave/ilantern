<?php
/**
 * Merged after config/config.php on every request. Keep declarative settings
 * here rather than in config.php so they survive `occ` rewrites and upgrades.
 */
$CONFIG = [
    // Silences the "no phone region" admin warning and fixes local number parsing.
    'default_phone_region' => getenv('NEXTCLOUD_DEFAULT_PHONE_REGION') ?: 'US',

    // Apply upgrades/heavy background jobs at 01:00-05:00 UTC.
    'maintenance_window_start' => 1,

    // Redis-backed distributed cache and file locking (the container sets
    // 'redis' itself from REDIS_HOST*; these opt the caches into using it).
    'memcache.local' => '\\OC\\Memcache\\APCu',
    'memcache.distributed' => '\\OC\\Memcache\\Redis',
    'memcache.locking' => '\\OC\\Memcache\\Redis',

    // Route the Nextcloud log through PHP's error_log, which Apache writes to
    // the container's stderr, so `docker compose logs app` is the single source
    // of truth. 2 = warnings and above.
    'log_type' => 'errorlog',
    'loglevel' => 2,
];
