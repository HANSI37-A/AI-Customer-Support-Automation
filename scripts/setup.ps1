# One-shot setup: start the stack, import credentials + the "Customer Support AI" workflow into n8n,
# publish it, and make sure the Qdrant collection exists. Run from the repo root:  .\scripts\setup.ps1
# Requires GEMINI_API_KEY in .env (copy .env.example to .env).
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
. "$PSScriptRoot\load-env.ps1"
if (-not $env:GEMINI_API_KEY -or $env:GEMINI_API_KEY -like '*your-gemini*') {
  Write-Warning 'GEMINI_API_KEY is not set in .env - AI nodes will fail until you add it.'
}
$n8nPort = if ($env:N8N_HOST_PORT) { $env:N8N_HOST_PORT } else { 5678 }
$qdrantPort = if ($env:QDRANT_HOST_PORT) { $env:QDRANT_HOST_PORT } else { 6333 }
$workflowId = 'CdAypnWR7xBZIEPc'   # id of n8n\backup\workflows\Customer Support AI.json

docker compose up -d
if ($LASTEXITCODE -ne 0) { throw 'docker compose up failed (is Docker Desktop running?)' }

Write-Host 'Waiting for n8n...'
$n8nReady = $false
for ($i = 0; $i -lt 60; $i++) {
  try {
    if ((Invoke-WebRequest "http://localhost:$n8nPort/healthz" -UseBasicParsing -TimeoutSec 3).StatusCode -eq 200) {
      $n8nReady = $true
      break
    }
  } catch { Start-Sleep 2 }
}
if (-not $n8nReady) { throw "Timed out waiting for n8n to respond on port $n8nPort" }

$n8n = (docker compose ps -q n8n)
$pg = (docker compose ps -q postgres)

# Apply init.sql on every run. It is idempotent (IF NOT EXISTS) and adds anything missing on older databases
# (sentiment column, ticket_seq sequence, indexes).
if (-not $pg) { throw 'PostgreSQL container is not running' }
Get-Content (Join-Path (Get-Location) 'init.sql') -Raw | docker exec -i $pg psql -U support -d supportdb -v ON_ERROR_STOP=1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Applying init.sql failed' }

# Credentials: Postgres comes from the backup file (password overridden from .env if set);
# SMTP is generated from .env (placeholder host if unset)
$pgCred = Get-Content 'n8n\backup\credentials\postgres.json' -Raw | ConvertFrom-Json
if ($env:POSTGRES_PASSWORD) { $pgCred[0].data.password = $env:POSTGRES_PASSWORD }
$tmpPg = Join-Path $env:TEMP 'n8n-pg-cred.json'
[IO.File]::WriteAllText($tmpPg, (ConvertTo-Json -InputObject @($pgCred) -Depth 10), (New-Object Text.UTF8Encoding $false))
$smtp = @(@{
  id = 'jVSAATUYNXSg0rEG'; name = 'SMTP account'; type = 'smtp'
  data = @{
    host = $(if ($env:SMTP_HOST) { $env:SMTP_HOST } else { 'localhost' })
    port = $(if ($env:SMTP_PORT) { [int]$env:SMTP_PORT } else { 25 })
    user = [string]$env:SMTP_USER; password = [string]$env:SMTP_PASSWORD
    secure = ($env:SMTP_PORT -eq '465'); disableStartTls = (-not $env:SMTP_HOST)
  }
})
$tmp = Join-Path $env:TEMP 'n8n-smtp-cred.json'
[IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $smtp -Depth 5), (New-Object Text.UTF8Encoding $false))

docker exec -u root $n8n rm -rf /tmp/n8n-import
docker exec -u root $n8n mkdir -p /tmp/n8n-import
docker cp $tmpPg "${n8n}:/tmp/n8n-import/postgres.json"
docker cp "n8n\backup\workflows\Customer Support AI.json" "${n8n}:/tmp/n8n-import/workflow.json"
docker cp $tmp "${n8n}:/tmp/n8n-import/smtp.json"
Remove-Item $tmp, $tmpPg
docker exec -u root $n8n chmod -R a+rX /tmp/n8n-import

docker exec $n8n n8n import:credentials --input=/tmp/n8n-import/postgres.json
if ($LASTEXITCODE -ne 0) { throw 'n8n import:credentials failed for postgres.json' }
docker exec $n8n n8n import:credentials --input=/tmp/n8n-import/smtp.json
if ($LASTEXITCODE -ne 0) { throw 'n8n import:credentials failed for smtp.json' }
docker exec $n8n n8n import:workflow --input=/tmp/n8n-import/workflow.json
if ($LASTEXITCODE -ne 0) { throw 'n8n import:workflow failed for workflow.json' }

# Older versions of this project used the same webhook path; make sure they are not active
foreach ($old in 'supportAutomation01', 'supportFeedback01') { docker exec $n8n n8n unpublish:workflow --id=$old 2>$null | Out-Null }
docker exec $n8n n8n publish:workflow --id=$workflowId
if ($LASTEXITCODE -ne 0) { throw 'n8n publish:workflow failed' }
docker exec -u root $n8n rm -rf /tmp/n8n-import
docker compose restart n8n   # publish/import take effect on restart

Write-Host 'Waiting for n8n restart...'
$n8nReady = $false
for ($i = 0; $i -lt 30 -and -not $n8nReady; $i++) {
  try {
    if ((Invoke-WebRequest "http://localhost:$n8nPort/healthz" -UseBasicParsing -TimeoutSec 3).StatusCode -eq 200) { $n8nReady = $true }
  } catch { Start-Sleep 2 }
}
if (-not $n8nReady) { throw "n8n did not come back on port $n8nPort after restart. Check: docker compose logs n8n" }

# /healthz answers before published workflows are registered, so the first webhook calls would get a 404.
# The feedback webhook answers 400 (missing parameters) once it is registered and 404 before.
# The support-message webhook answers 400 or 401 on empty body once registered and 404 before.
$hookReady = $false
for ($i = 0; $i -lt 60 -and -not $hookReady; $i++) {
  try {
    Invoke-WebRequest "http://localhost:$n8nPort/webhook/customer-feedback" -UseBasicParsing -TimeoutSec 3 | Out-Null
    $hookReady = $true
  } catch {
    $fbStatus = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    if ($fbStatus -ne 0 -and $fbStatus -ne 404) {
      try {
        Invoke-WebRequest "http://localhost:$n8nPort/webhook/support-message" -Method Post -Body '{}' -ContentType 'application/json' -UseBasicParsing -TimeoutSec 3 | Out-Null
        $hookReady = $true
      } catch {
        $smStatus = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($smStatus -ne 0 -and $smStatus -ne 404) { $hookReady = $true } else { Start-Sleep 1 }
      }
    } else { Start-Sleep 1 }
  }
}
if (-not $hookReady) { Write-Warning 'Webhooks are not registered yet. Check that the workflow is published: docker compose logs n8n' }

$exists = try { Invoke-RestMethod "http://localhost:$qdrantPort/collections/support_docs" | Out-Null; $true } catch { $false }
if (-not $exists) {
  Invoke-RestMethod -Method Put "http://localhost:$qdrantPort/collections/support_docs" -ContentType 'application/json' `
    -Body '{"vectors":{"size":1536,"distance":"Cosine"}}' | Out-Null
  Write-Host 'Created Qdrant collection support_docs'
}
Write-Host "Done. n8n: http://localhost:$n8nPort . Next: .\scripts\test-gemini.ps1, .\scripts\ingest-knowledge-base.ps1, .\scripts\test-webhooks.ps1"
