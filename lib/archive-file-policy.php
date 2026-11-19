<?php

declare(strict_types=1);

// A private, pre-copy record. Never infer preserved paths from post-copy state.
function refuse(string $reason): void
{
    throw new RuntimeException($reason);
}

function inventory(string $root): array
{
    $items = [];
    $walk = function (string $dir, string $prefix) use (&$walk, &$items): void {
        foreach (new DirectoryIterator($dir) as $item) {
            if ($item->isDot()) continue;
            $path = $prefix.$item->getFilename();
            if ($item->isLink()) refuse('symlink in source or preserved tree');
            if ($item->isDir()) {
                $items[$path] = ['directory'];
                $walk($item->getPathname(), $path.'/');
            } elseif ($item->isFile()) {
                $hash = hash_file('sha256', $item->getPathname());
                if ($hash === false) refuse('unreadable file');
                $items[$path] = ['file', $hash];
            } else refuse('unsupported file type');
            if (count($items) > 500000) refuse('file inventory exceeds limit');
        }
    };
    $walk($root, '');
    ksort($items, SORT_STRING);
    return $items;
}

function snapshot(string $path): array
{
    $resolved = realpath($path);
    $link = readlink($path);
    if ($resolved === false || $link === false) refuse('unresolved preserved link');
    if (is_dir($resolved)) $tree = ['directory', inventory($resolved)];
    elseif (is_file($resolved)) {
        $hash = hash_file('sha256', $resolved);
        if ($hash === false) refuse('unreadable preserved file');
        $tree = ['file', $hash];
    } else refuse('unsupported preserved link target');
    return ['link' => $link, 'resolved' => $resolved, 'sha256' => hash('sha256', json_encode($tree, JSON_THROW_ON_ERROR))];
}

function excluded(string $relative): bool
{
    $parts = explode('/', $relative);
    if ($parts[0] !== 'plugins' || count($parts) < 2) return false;
    $name = $parts[1];
    return in_array($name, ['nginx-helper', 'redis-cache', 'redis-object-cache', 'redis-cache-pro', 'gridpane-redis-object-cache', 'wp-redis', 'wp-redis-cache', 'object-cache-pro'], true)
        || preg_match('/redis.*object.*cache/', $name) === 1;
}

function firstLink(string $root, string $relative): ?string
{
    $parts = explode('/', $relative);
    $prefix = '';
    foreach ($parts as $part) {
        if ($part === '' || $part === '.' || $part === '..') refuse('invalid relative path');
        $prefix .= ($prefix === '' ? '' : '/').$part;
        if (is_link($root.'/'.$prefix)) return $prefix;
    }
    return null;
}

function sourceFiles(string $source): array
{
    $files = [];
    foreach (inventory($source) as $path => $entry) {
        if ($entry[0] !== 'file') continue;
        if (!in_array(explode('/', $path)[0], ['plugins', 'themes', 'uploads'], true)) refuse('unsupported selected archive path');
        $files[$path] = $entry[1];
    }
    if (!$files) refuse('empty selected archive');
    return $files;
}

try {
    if ($argc !== 6) refuse('expected capture|verify POLICY SOURCE TARGET ARCHIVE_SHA256');
    [, $mode, $policy, $source, $target, $sha] = $argv;
    if (!in_array($mode, ['capture', 'verify'], true) || !preg_match('/\A[a-f0-9]{64}\z/', $sha)) refuse('invalid policy arguments');
    if (is_link($source) || !is_dir($source) || !is_dir($target)) refuse('invalid content roots');
    $source = realpath($source);
    $target = realpath($target);
    if ($source === false || $target === false || $source === $target) refuse('invalid canonical roots');
    // The merge skips links within a category, but follows category roots.
    // Reject these layouts before recording evidence or changing the destination.
    foreach (['plugins', 'themes', 'uploads'] as $category) {
        if (is_link($target.'/'.$category)) refuse('unsupported content directory symlink');
    }
    $files = sourceFiles($source);
    if ($mode === 'capture') {
        $links = [];
        $entries = [];
        foreach ($files as $path => $hash) {
            if (excluded($path)) $entries[$path] = ['excluded', $hash];
            elseif (($link = firstLink($target, $path)) !== null) {
                if (!isset($links[$link])) $links[$link] = snapshot($target.'/'.$link);
                $entries[$path] = ['preserved', $hash, $link];
            } else $entries[$path] = ['copied', $hash];
        }
        $data = ['schema_version' => 1, 'archive_sha256' => $sha, 'source' => $source, 'target' => $target, 'entries' => $entries, 'links' => $links];
        // Exclusive creation: a repeat restore must not replace its original evidence.
        $handle = @fopen($policy, 'x');
        if ($handle === false) refuse('policy already exists or is unavailable');
        if (!chmod($policy, 0600)) refuse('cannot protect policy');
        $json = json_encode($data, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES);
        if (fwrite($handle, $json) !== strlen($json) || !fflush($handle)) refuse('cannot persist policy');
        fclose($handle);
        exit(0);
    }
    if (!is_file($policy) || is_link($policy) || filesize($policy) > 128 * 1024 * 1024) refuse('policy unavailable');
    $data = json_decode(file_get_contents($policy), true, 512, JSON_THROW_ON_ERROR);
    if (!is_array($data) || ($data['schema_version'] ?? null) !== 1 || ($data['archive_sha256'] ?? null) !== $sha
        || ($data['source'] ?? null) !== $source || ($data['target'] ?? null) !== $target
        || !is_array($data['entries'] ?? null) || !is_array($data['links'] ?? null)
        || array_keys($data['entries']) !== array_keys($files)) refuse('policy binding or inventory mismatch');
    $used = [];
    $copied = 0;
    $media = 0;
    foreach ($files as $path => $hash) {
        $entry = $data['entries'][$path];
        if (!is_array($entry) || ($entry[1] ?? null) !== $hash) refuse('staged source changed');
        if (excluded($path)) {
            if ($entry !== ['excluded', $hash]) refuse('invalid exclusion');
            continue;
        }
        $link = firstLink($target, $path);
        if (($entry[0] ?? null) === 'preserved') {
            if ($entry !== ['preserved', $hash, $link] || $link === null || !isset($data['links'][$link])) refuse('preserved path changed');
            if (!isset($used[$link]) && snapshot($target.'/'.$link) !== $data['links'][$link]) refuse('preserved target changed');
            $used[$link] = true;
        } else {
            if ($entry !== ['copied', $hash] || $link !== null || !is_file($target.'/'.$path)
                || hash_file('sha256', $target.'/'.$path) !== $hash) refuse('copied file changed');
            $copied++;
            if (str_starts_with($path, 'uploads/')) $media++;
        }
    }
    if (array_diff_key($data['links'], $used)) refuse('unused preservation entry');
    printf("files=yes\nmigrated_files_count=%d\nmedia_count=%d\npreserved_paths_count=%d\n", $copied, $media, count($used));
} catch (Throwable $error) {
    // Fixed messages only: paths, archive contents and raw runtime errors stay private.
    fwrite(STDERR, "Archive file policy validation failed.\n");
    exit(1);
}
