<?php

$dir = $argv[1];
$fields = ['ID', 'post_type', 'post_status', 'post_name', 'post_title', 'post_content', 'post_excerpt', 'post_parent', 'menu_order'];
$row = ['1', 'post', 'publish', 'evidence', 'initial', 'https://source.test/a', "line\nnext", '0', '0'];
// SQL escapes and URL replacement must survive without exposing raw content.
$row[4] = "Quote ' and slash \\";
$sql = 'CREATE TABLE `custom_posts` ('.implode(',', array_map(fn ($f) => '`'.$f.'` text', $fields)).");\nINSERT INTO `custom_posts` VALUES (".implode(',', array_map(fn ($v) => "'".str_replace(['\\', "'", "\n"], ['\\\\', "\\'", '\\n'], $v)."'", $row)).");\n";
$z = new ZipArchive;
$z->open($dir.'/backup.zip', ZipArchive::CREATE);
$z->addFromString('wp-content/mysql.sql', $sql);
$z->addFromString('wp-content/mu-plugins/wpengine-common/test.php', 'excluded');
$z->close();
$actual = array_combine($fields, $row);
$actual['post_content'] = 'https://destination.test/a';
file_put_contents($dir.'/actual.json', json_encode([$actual]));
$actual['post_title'] = 'corrupted';
file_put_contents($dir.'/corrupt.json', json_encode([$actual]));
file_put_contents($dir.'/empty.json', '[]');
foreach (['unknown' => 'wp-content/mu-plugins/customer.php', 'lookalike' => 'wp-content/mu-plugins/wpengine-common-custom/test.php', 'dropin' => 'wp-content/db.php'] as $name => $path) {
    copy($dir.'/backup.zip', $dir.'/'.$name.'.zip');
    $z->open($dir.'/'.$name.'.zip');
    $z->addFromString($path, 'custom');
    $z->close();
}

foreach ([
    'duplicate' => $sql."INSERT INTO `custom_posts` VALUES (1,'post','publish','same','Title','Body','',0,0);\n",
    'unquoted' => str_replace('INSERT INTO `custom_posts`', 'INSERT INTO custom_posts', $sql),
    'columns' => str_replace('INSERT INTO `custom_posts` VALUES', 'INSERT INTO `custom_posts` (`ID`) VALUES', $sql),
    'truncated' => substr($sql, 0, -2),
    'mode' => "SET sql_mode='NO_BACKSLASH_ESCAPES';\n".$sql,
    'ambiguous' => $sql.str_replace('custom_posts', 'other_posts', $sql),
] as $name => $bad) {
    copy($dir.'/backup.zip', $dir.'/'.$name.'.zip');
    $z->open($dir.'/'.$name.'.zip');
    $z->addFromString('wp-content/mysql.sql',$bad);
    $z->close();
}

copy($dir.'/backup.zip', $dir.'/oversized.zip');
$z->open($dir.'/oversized.zip');
$large = fopen($dir.'/oversized.sql', 'w+b');
ftruncate($large, 67108865);
fclose($large);
$z->addFile($dir.'/oversized.sql', 'wp-content/mysql.sql');
$z->close();

// Reviewed provider families: exact entrypoints and directory contents only.
$reviewed = ['mu-plugins/wpe-update-source-selector.php', 'mu-plugins/wpe-update-source-selector', 'mu-plugins/wpe-cache-plugin.php', 'mu-plugins/wpe-cache-plugin', 'mu-plugins/wpe-wp-sign-on-plugin.php', 'mu-plugins/wpe-wp-sign-on-plugin', 'mu-plugins/wpengine-security-auditor.php'];
copy($dir.'/backup.zip', $dir.'/reviewed.zip');
$z->open($dir.'/reviewed.zip');
foreach ($reviewed as $component) {
    $z->addFromString('wp-content/'.$component.(str_ends_with($component, '.php') ? '' : '/inc/component.php'), '<?php');
}
$z->close();
$blocked = ['wpe-cache-plugin-custom/custom.php', 'wpe-cache-plugin.php.bak', 'wpe-wp-sign-on-plugin-custom/custom.php', 'wpe-wp-sign-on-plugin.php.custom', 'wpengine-security-auditor.php.custom', 'wpengine-security-auditor.php/custom.php', 'wpengine-security-auditor/custom.php', 'wpe-update-source-selector.php.custom', 'wpe-update-source-selector.php/custom.php', 'wpe-update-source-selector-custom/classes/selector.php'];
foreach ($blocked as $index => $component) {
    copy($dir.'/reviewed.zip', $dir.'/blocked-'.$index.'.zip');
    $z->open($dir.'/blocked-'.$index.'.zip');
    $z->addFromString('wp-content/mu-plugins/'.$component, '<?php');
    $z->close();
}
