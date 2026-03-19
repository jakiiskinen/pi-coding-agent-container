# Claude Code Instructions — Pi Coding Agent Container

## PowerShell Scripting Rules

These rules apply to ALL .ps1 files in this repo. Violations cause silent failures
or parse errors in Windows PowerShell 5.1 (the default on Windows).

### No Unicode characters in .ps1 files
PowerShell 5.1 misparsed UTF-8 files containing non-ASCII characters, causing
cascade brace errors. Use plain ASCII only.

- BAD:  `# ── Section ──────────`
- GOOD: `# --- Section -----------`
- BAD:  `Write-Error "failed — try again"`
- GOOD: `Write-Error "failed - try again"`

### No && in SSH command strings
PowerShell 5.1 treats `&&` as an invalid token even inside double-quoted strings.

- BAD:  `ssh user@host "cd $path && docker compose build"`
- GOOD: `ssh user@host "docker compose -f $path/docker-compose.yml build"`

### Always use the pi-vm SSH alias
SSH commands must use `pi-vm` (defined in ~/.ssh/config with key, user, IP,
and StrictHostKeyChecking=no). Never connect by raw IP or user@host.

- BAD:  `ssh "${vmUser}@${vmHost}" "..."`
- BAD:  `scp file.txt "${vmUser}@${vmHost}:path"`
- GOOD: `ssh pi-vm "..."`
- GOOD: `scp file.txt "pi-vm:path"`

### Always add a trap for error visibility
Every .ps1 script launched from a .bat file must have a top-level trap so errors
are visible before the window closes.

```powershell
trap {
    Write-Host ""
    Write-Host "ERROR: $_" -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}
```

### No semicolons in commands passed to wt
`wt` treats `;` as its own subcommand separator. Any string containing `;`
passed as a `-Command` argument to `wt` will be misparsed.

- BAD:  `wt new-tab powershell -Command "ssh pi-vm 'cmd1; cmd2'"`
- GOOD: Build the command before calling wt so it contains no semicolons.
        Pre-compute any branching logic (if/else) in PowerShell first.

### .bat launchers must pause on error
```batch
powershell -ExecutionPolicy Bypass -File "%~dp0script.ps1"
if %errorlevel% neq 0 pause
```

## .env File Rules

Inline comments are not valid .env syntax — parsers read them as part of the value.

- BAD:  `UID=1000   # run id -u to find this`
- GOOD: `# run id -u to find this`
        `UID=1000`
