<?php

declare(strict_types=1);

// Read a bounded mysqldump subset as data. Never execute SQL or derive the baseline
// from the imported destination. Unsupported dump syntax fails closed.
const CONTENT_FIELDS = ['ID', 'post_type', 'post_status', 'post_name', 'post_title', 'post_content', 'post_excerpt', 'post_parent', 'menu_order'];
function contentFail(): void
{
    throw new RuntimeException('Unsupported or contradictory archive content evidence');
}
function sqlTokens(string $sql): Generator
{
    $offset = 0;
    $pattern = '~\G(?:\s+|--[^\r\n]*(?:\r?\n|$)|\#[^\r\n]*(?:\r?\n|$)|/\*.*?\*/|`(?:``|[^`])*`|\'(?:\\\\.|\'\'|[^\'\\\\])*\'|[A-Za-z_][A-Za-z_0-9$]*|-?[0-9]+(?:\.[0-9]+)?|[(),;=.+*/@-])~s';
    while ($offset < strlen($sql)) {
        if ($sql[$offset] === "'") {
            $start = $offset++;
            $closed = false;
            while ($offset < strlen($sql)) {
                if ($sql[$offset] === '\\') {
                    $offset += 2;

                    continue;
                }
                if ($sql[$offset++] === "'") {
                    if (($sql[$offset] ?? '') === "'") {
                        $offset++;

                        continue;
                    }
                    $closed = true;
                    break;
                }
            }
            if (! $closed) {
                contentFail();
            }
            yield substr($sql, $start, $offset - $start);

            continue;
        }
        if (! preg_match($pattern, $sql, $m, 0, $offset)) {
            contentFail();
        }
        $offset += strlen($m[0]);
        $t = $m[0];
        if (ctype_space($t) || str_starts_with($t, '--') || $t[0] === '#' || str_starts_with($t, '/*')) {
            if (str_starts_with($t, '/*!') && preg_match('/\b(?:INSERT|REPLACE|UPDATE|DELETE|CREATE|TRUNCATE|NO_BACKSLASH_ESCAPES|ANSI_QUOTES)\b/i', $t)) {
                contentFail();
            }

            continue;
        }
        yield $t;
    }
}
function sqlValue(string $token): ?string
{
    if (strtoupper($token) === 'NULL') {
        return null;
    }
    if (preg_match('/\A-?[0-9]+\z/', $token)) {
        return $token;
    }
    if ($token[0] !== "'" || substr($token, -1) !== "'") {
        contentFail();
    }
    $s = substr($token, 1, -1);
    $out = '';
    for ($i = 0; $i < strlen($s); $i++) {
        if ($s[$i] === '\\') {
            $i++;
            if ($i >= strlen($s)) {
                contentFail();
            }
            $out .= ['0' => "\0", 'n' => "\n", 'r' => "\r", 't' => "\t", 'b' => "\x08", 'Z' => "\x1a"][$s[$i]] ?? $s[$i];
        } elseif ($s[$i] === "'" && ($s[$i + 1] ?? '') === "'") {
            $out .= "'";
            $i++;
        } else {
            $out .= $s[$i];
        }
    }

    return $out;
}
function canonicalContent(array $rows, string $old, string $new): array
{
    $out = [];
    foreach ($rows as $row) {
        if (! is_array($row)) {
            contentFail();
        }
        $item = [];
        foreach (CONTENT_FIELDS as $key) {
            if (! isset($row[$key]) || ! is_scalar($row[$key])) {
                contentFail();
            }
            $value = (string) $row[$key];
            if (in_array($key, ['ID', 'post_parent', 'menu_order'], true)) {
                if (! preg_match('/\A-?[0-9]+\z/', $value)) {
                    contentFail();
                }
                if ((string) (int) $value !== $value) { contentFail(); }
                $value = (string) (int) $value;
            } else {
                $value = str_replace($old, $new, $value);
            }
            $item[$key] = $value;
        }
        if (! in_array($item['post_status'], ['publish','future','draft','pending','private','trash','auto-draft','inherit'], true)) { contentFail(); }
        if (! in_array($item['post_type'], ['post', 'page'], true) || isset($out[$item['ID']])) {
            contentFail();
        }
        $out[$item['ID']] = $item;
    }
    ksort($out, SORT_NUMERIC);

    return array_values($out);
}
function archiveContent(string $sql): array
{
    $columns = [];
    $table = null;
    $rows = [];
    $statement = [];
    foreach (sqlTokens($sql) as $token) {
        if (count($statement) > 1000000) {
            contentFail();
        }
        if ($token !== ';') {
            $statement[] = $token;

            continue;
        }
        $s = $statement;
        $statement = [];
        if (! $s) {
            continue;
        }
        if (strtoupper($s[0]) === 'SET' && preg_match('/\b(?:NO_BACKSLASH_ESCAPES|ANSI_QUOTES)\b/i', implode(' ', $s))) {
            contentFail();
        }
        $upper = array_map('strtoupper', array_slice($s, 0, 4));
        if (($upper[0] ?? '') === 'CREATE' && ($upper[1] ?? '') === 'TABLE' && preg_match('/\A`([A-Za-z0-9_]+_posts)`\z/', $s[2] ?? '', $m)) {
            if ($table !== null || ($s[3] ?? '') !== '(') {
                contentFail();
            }
            $table = $m[1];
            $depth = 1;
            $start = true;
            for ($i = 4; $i < count($s) && $depth > 0; $i++) {
                if ($depth === 1 && $start && $s[$i][0] === '`') {
                    $columns[] = trim($s[$i], '`');
                }
                $start = false;
                if ($s[$i] === '(') {
                    $depth++;
                }
                if ($s[$i] === ')') {
                    $depth--;
                }
                if ($depth === 1 && $s[$i] === ',') {
                    $start = true;
                }
            }
            if (array_diff(CONTENT_FIELDS, $columns) || count($columns) !== count(array_unique($columns))) {
                contentFail();
            }
        } elseif (($upper[0] ?? '') === 'INSERT' && ($upper[1] ?? '') === 'INTO' && preg_match('/\A`([A-Za-z0-9_]+_posts)`\z/', $s[2] ?? '', $m)) {
            if ($table !== $m[1] || strtoupper($s[3] ?? '') !== 'VALUES') {
                contentFail();
            }
            $i = 4;
            while ($i < count($s)) {
                if ($s[$i++] !== '(') {
                    contentFail();
                } $values = [];
                do {
                    if (! isset($s[$i])) {
                        contentFail();
                    } $values[] = sqlValue($s[$i++]);
                    $separator = $s[$i++] ?? null;
                } while ($separator === ',');
                if ($separator !== ')' || count($values) !== count($columns)) {
                    contentFail();
                }
                $row = array_combine($columns, $values);
                if (in_array($row['post_type'] ?? null, ['post', 'page'], true)) {
                    $rows[] = $row;
                }
                if (count($rows) > 100000) {
                    contentFail();
                }
                if ($i < count($s)) {
                    if ($s[$i++] !== ',' || $i === count($s)) {
                        contentFail();
                    }
                }
            }
        } elseif (array_filter($s, static fn ($token) => preg_match('/\A`?[A-Za-z0-9_]+_posts`?\z/', $token))) {
            // Standard dump framing only; no mutations outside supported INSERT.
            if (! in_array($upper[0] ?? '', ['DROP', 'LOCK', 'UNLOCK', 'ALTER'], true)) {
                contentFail();
            }
            if (($upper[0] ?? '') === 'ALTER' && ! preg_match('/\AALTER TABLE `[A-Za-z0-9_]+_posts` (?:DISABLE|ENABLE) KEYS\z/i', implode(' ', $s))) {
                contentFail();
            }
        }
    }
    if ($statement || $table === null) {
        contentFail();
    }

    return $rows;
}
try {
    if ($argc !== 6 || ! in_array($argv[1], ['inspect', 'verify'], true)) {
        contentFail();
    }
    [, $mode,$archive,$sha,$old,$new] = $argv;
    if (! preg_match('/\A[a-f0-9]{64}\z/', $sha) || ! hash_equals($sha, hash_file('sha256', $archive))) {
        contentFail();
    }
    foreach ([$old, $new] as $url) {
        if (! preg_match('~\Ahttps?://[^\s]+\z~', $url)) {
            contentFail();
        }
    }
    $zip = new ZipArchive;
    if ($zip->open($archive, ZipArchive::RDONLY) !== true) {
        contentFail();
    }
    $names = [];
    for ($i = 0; $i < $zip->numFiles; $i++) {
        if (preg_match('~(?:^|/)wp-content/mysql\.sql$~', $zip->getNameIndex($i))) {
            $names[] = $zip->getNameIndex($i);
        }
    }
    if (count($names) !== 1) {
        contentFail();
    }
    $stat = $zip->statName($names[0]);
    if ($stat['size'] > 67108864) {
        contentFail();
    }
    $sql = $zip->getFromName($names[0]);
    if (! is_string($sql) || strlen($sql) !== $stat['size']) {
        contentFail();
    }
    $expected = canonicalContent(archiveContent($sql), $old, $new);
    $digest = hash('sha256', json_encode($expected, JSON_THROW_ON_ERROR | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
    if ($mode === 'verify') {
        $raw = stream_get_contents(STDIN, 67108865);
        if (strlen($raw) > 67108864) {
            contentFail();
        }
        $actual = json_decode($raw, true, 512, JSON_THROW_ON_ERROR);
        if (! is_array($actual) || array_keys($actual) !== array_keys(array_values($actual))) {
            contentFail();
        }
        if (canonicalContent($actual, $old, $old) !== $expected) {
            contentFail();
        }
    }
    echo 'content_count='.count($expected)."\ncontent_sha256=$digest\n";
} catch (Throwable $e) {
    fwrite(STDERR,"Archive content evidence unavailable or mismatched\n");
    exit(1);
}
