# Runs app.exe under the RAD Debugger. A breakpoint on a source line of work, which the exe has and
# each patch changes, must stop in the body of the exe, then of v2, then of v3, and never in an old
# body. Run build.bat first. RADDBG is raddbg.exe (default: raddbg on PATH). Without it, the test is
# skipped, except in CI ($env:CI), where it fails.
#
# The script controls raddbg through its IPC port (TCP, 127.0.0.1:7423): it sends a command as text,
# and raddbg replies with the output of the command. raddbg runs the commands only when it has a
# window.

$raddbg = if ($env:RADDBG) { $env:RADDBG } else { (Get-Command raddbg -ErrorAction Ignore).Source }
if (-not $raddbg -or -not (Test-Path $raddbg)) {
    if ($env:CI) { Write-Host '  FAIL  raddbg not found'; exit 1 }
    Write-Host '  skipped: raddbg not found (set RADDBG or put raddbg on PATH)'
    exit 0
}

$main = Join-Path $PSScriptRoot 'main.odin'
# The line of the breakpoint: it has the comment "the debugger breaks here"
$line = (Select-String -Path $main -Pattern 'the debugger breaks here').LineNumber
$log = Join-Path $PSScriptRoot 'raddbg.log'
Set-Content $log ''

# Sends one IPC command and returns the reply. The parts of a reply are separated by NUL.
function ipc($command) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $client.Connect('127.0.0.1', 7423)
        $stream = $client.GetStream()
        $bytes = [Text.Encoding]::UTF8.GetBytes($command)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.ReadTimeout = 15000
        $buffer = New-Object byte[] 65536
        $reply = [Text.StringBuilder]::new()
        $count = $stream.Read($buffer, 0, $buffer.Length)
        while ($count -gt 0) {
            [void]$reply.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $count))
            Start-Sleep -Milliseconds 100
            if (-not $stream.DataAvailable) { break }
            $count = $stream.Read($buffer, 0, $buffer.Length)
        }
        $text = $reply.ToString() -replace "`0", "`n"
        Add-Content $log "> $command`n$text"
        return $text
    } catch {
        Add-Content $log "> $command`nIPC error: $_"
        return ''
    } finally {
        $client.Dispose()
    }
}

# The number of stops so far
function stop_count($state) {
    if ($state -match '(?m)^\s*stop_count: (\d+)') { [int]$Matches[1] } else { -1 }
}

# Waits for a stop after stop number $after, and returns the state. Empty after a time-out.
# Right after a continue, the state can still show the old stop.
function wait_stop($after, $seconds = 120) {
    $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $seconds) {
        Start-Sleep -Milliseconds 300
        $state = ipc 'state'
        if ($state -match '(?m)^\s*running: 0\s*$' -and (stop_count $state) -gt $after) { return $state }
    }
    return ''
}

# A user file of its own: the test must not use or change the settings of the person who runs it
$user = Join-Path $PSScriptRoot 'test.raddbg_user'
Remove-Item -ErrorAction Ignore $user
$debugger = Start-Process $raddbg -ArgumentList "--user:$user", (Join-Path $PSScriptRoot 'app.exe') -WorkingDirectory $PSScriptRoot -PassThru

$failed = $false
function check($label, $ok) {
    if ($ok) { Write-Host "  OK    $label" } else { Write-Host "  FAIL  $label"; $script:failed = $true }
}

try {
    # Wait until raddbg answers on its IPC port
    $ready = $false
    $start = Get-Date
    while (-not $ready -and ((Get-Date) - $start).TotalSeconds -lt 60) {
        Start-Sleep -Milliseconds 500
        $ready = (ipc 'state') -match 'state:'
    }
    check 'raddbg answers on its IPC port' $ready
    if ($ready) {
        ipc "add_breakpoint ${main}:$line" | Out-Null
        $stops = stop_count (ipc 'state')
        ipc 'run' | Out-Null
        foreach ($v in 1, 2, 3) {
            $state = wait_stop $stops
            $stops = stop_count $state
            check "v${v}: stopped" ($state -ne '')
            if (-not $state) { break }
            $module = if ($state -match 'ip_module: "([^"]*)"') { $Matches[1] } else { '' }
            $symbol = if ($state -match 'ip_voff_symbol: "([^"]*)"') { $Matches[1] } else { '' }
            $want_module = if ($v -eq 1) { '^app\.exe$' } else { '^lp_\w+\.dll$' }
            check "v${v}: in work ($symbol)" ($symbol -eq 'main::work')
            check "v${v}: in the module of v$v ($module)" ($module -match $want_module)
            check "v${v}: on line $line" ($state -match "(?m)^\s*line_num:\s+$line\s*$")
            $eval = ipc 'eval body_version'
            check "v${v}: body_version is $v" ($eval -match "value:\s+`"$v`"")
            ipc 'continue' | Out-Null
        }
        # After v3, the program runs to its end: a fourth stop at the breakpoint would be an old body
        $end = wait_stop $stops 60
        $fourth = $end -match 'ip_voff_symbol: "main::work"' -and $end -match "(?m)^\s*line_num:\s+$line\s*$"
        check 'no stop in an old body' (-not $fourth)
    }
} finally {
    ipc 'kill_all' | Out-Null
    ipc 'exit' | Out-Null
    Start-Sleep -Seconds 2
    if (-not $debugger.HasExited) { Stop-Process -Id $debugger.Id -Force -ErrorAction Ignore }
}

Write-Host "--- raddbg IPC log ($log):"
Get-Content $log | Write-Host
if ($failed) { exit 1 }
