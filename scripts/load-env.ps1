# Dot-source to load .env from the repo root into this PowerShell session.
$envFile = Join-Path (Split-Path $PSScriptRoot -Parent) '.env'
if (Test-Path $envFile) {
  Get-Content $envFile | Where-Object { $_ -match '^\s*[^#\s][^=]*=' } | ForEach-Object {
    $k, $v = $_ -split '=', 2
    [Environment]::SetEnvironmentVariable($k.Trim(), $v.Trim().Trim('"'), 'Process')
  }
}
