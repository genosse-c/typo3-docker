<?php
// typo3-docker: managed file.
// Database credentials and trusted hosts come from the container environment, so a backup can be
// restored into any instance of this stack regardless of the credentials stored in settings.php.
defined('TYPO3') or die();

$GLOBALS['TYPO3_CONF_VARS']['DB']['Connections']['Default'] = array_replace(
    $GLOBALS['TYPO3_CONF_VARS']['DB']['Connections']['Default'] ?? [],
    [
        'driver' => 'mysqli',
        'host' => getenv('TYPO3_DB_HOST') ?: 'db',
        'port' => (int)(getenv('TYPO3_DB_PORT') ?: 3306),
        'dbname' => (string)getenv('TYPO3_DB_DBNAME'),
        'user' => (string)getenv('TYPO3_DB_USERNAME'),
        'password' => (string)getenv('TYPO3_DB_PASSWORD'),
    ]
);

$trustedHostsPattern = getenv('TYPO3_TRUSTED_HOSTS_PATTERN');
if (is_string($trustedHostsPattern) && $trustedHostsPattern !== '') {
    $GLOBALS['TYPO3_CONF_VARS']['SYS']['trustedHostsPattern'] = $trustedHostsPattern;
}
unset($trustedHostsPattern);
