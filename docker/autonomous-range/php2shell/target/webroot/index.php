<?php
session_start();
echo "PHP " . PHP_VERSION . "\n";
echo "SAPI " . php_sapi_name() . "\n";
echo "upload_progress " . ini_get('session.upload_progress.enabled') . "\n";
if (isset($_POST['message'])) {
    echo "Hello, " . htmlspecialchars($_POST['message']) . "\n";
}
echo "OK\n";
