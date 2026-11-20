<?php

declare(strict_types=1);
try {
    if ($argc !== 3) {
        throw new RuntimeException;
    }
    $zip = new ZipArchive;
    if ($zip->open($argv[1], ZipArchive::RDONLY) !== true || ! hash_equals($argv[2], hash_file('sha256', $argv[1]))) {
        throw new RuntimeException;
    }
    $catalog = json_decode(file_get_contents(__DIR__.'/wp-engine-archive-rules.json'), true, 512, JSON_THROW_ON_ERROR);
    $roots = [];
    $names = [];
    for ($i = 0; $i < $zip->numFiles; $i++) {
        $name = $zip->getNameIndex($i);
        $names[] = $name;
        if (preg_match('~\A(.*)wp-content/mysql\.sql\z~', $name, $m)) {
            $roots[] = $m[1];
        }
    }
    if (count($roots) !== 1) {
        throw new RuntimeException;
    }
    $rules = [];
    foreach ($names as $name) {
        if (substr($name, -1) === '/') {
            continue;
        }
        $prefix = $roots[0].'wp-content/';
        if (! str_starts_with($name, $prefix)) {
            continue;
        }
        $relative = substr($name, strlen($prefix));
        $known = false;
        foreach ($catalog as $path => $id) {
            if ($relative === $path || (! str_ends_with($path, '.php') && str_starts_with($relative, $path.'/'))) {
                $rules[$id] = true;
                $known = true;
                break;
            }
        }
        if (! $known && (str_starts_with($relative, 'mu-plugins/')
            || in_array($relative, ['db.php', 'sunrise.php', 'object-cache.php', 'advanced-cache.php', 'maintenance.php', 'db-error.php', 'install.php', 'php-error.php', 'fatal-error-handler.php'], true)
            || preg_match('~\Aplugins/[^/]*redis[^/]*object[^/]*cache[^/]*(?:/|$)~', $relative))) {
            throw new RuntimeException;
        }
    }
    ksort($rules, SORT_STRING);
    echo json_encode(['profile_id' => 'wp-engine-v1', 'unknown_components_count' => 0, 'rules' => array_map(static fn ($id) => ['rule_id' => $id, 'outcome' => 'excluded_from_source'], array_keys($rules))], JSON_THROW_ON_ERROR)."\n";
} catch (Throwable $e) {
    fwrite(STDERR, "Archive normalization requires review; unknown components are blocked\n");
    exit(1);
}
