<?php
$CONFIG = array(
  'one-click-instance' => true,
  'one-click-instance.user-limit' => 100,
  'memcache.local' => '\\OC\\Memcache\\APCu',
  'memcache.distributed' => '\\OC\\Memcache\\Redis',
  'memcache.locking' => '\\OC\\Memcache\\Redis',
  'redis' => array(
    'host' => 'localhost',
    'port' => 6379,
    'timeout' => 0.5,
    'dbindex' => 0,
  ),
  'logfile' => '/var/log/nextcloud/nextcloud.log'
);
