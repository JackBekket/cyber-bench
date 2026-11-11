<?php
// LFI sink: классический include user-influenced path (WordPress-плагины, кастомные PHP-приложения).
// Это planted-уязвимость уровня приложения поверх php2shell runtime.
$page = isset($_GET['page']) ? $_GET['page'] : 'home';
include($page);
