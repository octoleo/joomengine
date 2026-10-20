<?php

declare(strict_types=1);

// Exercise the process primitives used by the MCP job launcher as the actual
// service user. No Joomla database or application mutation is needed.
if (PHP_SAPI !== 'cli') {
    fwrite(STDERR, "MCP workers require the CLI SAPI.\n");
    exit(1);
}

foreach (['pcntl_fork', 'pcntl_waitpid', 'pcntl_wifexited', 'pcntl_wexitstatus', 'posix_setsid', 'proc_open', 'proc_close'] as $function) {
    if (!function_exists($function)) {
        fwrite(STDERR, "Missing MCP worker function: {$function}\n");
        exit(1);
    }
}

$pid = pcntl_fork();
if ($pid === -1) {
    fwrite(STDERR, "Unable to fork an MCP worker.\n");
    exit(1);
}

if ($pid === 0) {
    if (posix_setsid() === -1) {
        fwrite(STDERR, "Unable to detach an MCP worker.\n");
        exit(1);
    }

    $process = proc_open(
        [PHP_BINARY, '-r', 'fwrite(STDOUT, "mcp-worker-ready");'],
        [0 => ['file', '/dev/null', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
        $pipes,
        null,
        null,
        ['bypass_shell' => true]
    );
    if (!is_resource($process)) {
        fwrite(STDERR, "Unable to launch the MCP worker subprocess.\n");
        exit(1);
    }
    $output = stream_get_contents($pipes[1]);
    $errors = stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    $exitCode = proc_close($process);
    if ($exitCode !== 0 || $output !== 'mcp-worker-ready' || $errors !== '') {
        fwrite(STDERR, "MCP worker subprocess failed.\n");
        exit(1);
    }
    exit(0);
}

if (pcntl_waitpid($pid, $status) !== $pid || !pcntl_wifexited($status) || pcntl_wexitstatus($status) !== 0) {
    fwrite(STDERR, "Detached MCP worker did not complete successfully.\n");
    exit(1);
}

fwrite(STDOUT, "MCP fork, detached session and subprocess execution passed.\n");
