# End-to-end test of both webhooks, with pass/fail results. Exits with code 1 if anything fails.
#   POST /webhook/support-message     validates, replies 202 + ticket_id, then the AI work runs in the background
#   GET  /webhook/customer-feedback   stores a good/bad rating for an existing ticket
# Needs the stack from .\scripts\setup.ps1, a working GEMINI_API_KEY and the knowledge base loaded.
# Each run saves one test ticket (email test+<time>@example.com) and a few feedback rows.
# Usage: .\scripts\test-webhooks.ps1 [-Message "..."] [-TimeoutSec 180]
param(
  [string]$Message = 'How do I reset my password?',
  [int]$TimeoutSec = 180
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\load-env.ps1"
$port = if ($env:N8N_HOST_PORT) { $env:N8N_HOST_PORT } else { 5678 }
$base = "http://localhost:$port/webhook"
$pg = (docker compose ps -q postgres)
if (-not $pg) { throw 'PostgreSQL container is not running. Start the stack first using: .\scripts\setup.ps1' }

$script:failed = 0
function Check($name, [bool]$ok, $detail = '') {
  if ($ok) { Write-Host "  PASS  $name" -ForegroundColor Green }
  else { Write-Host "  FAIL  $name  $detail" -ForegroundColor Red; $script:failed++ }
}
function Query($sql) { (docker exec $pg psql -U support -d supportdb -At -F '|' -c $sql) -join "`n" }

# Returns @{ Status; Body } for any HTTP status instead of throwing on 4xx/5xx
function Call($method, $url, $json = $null, $headers = @{}) {
  try {
    $p = @{ Method = $method; Uri = $url; UseBasicParsing = $true; Headers = $headers; TimeoutSec = 30 }
    if ($null -ne $json) { $p.Body = [Text.Encoding]::UTF8.GetBytes($json); $p.ContentType = 'application/json' }
    $r = Invoke-WebRequest @p
    return @{ Status = [int]$r.StatusCode; Body = $r.Content }
  } catch [System.Net.WebException] {
    $resp = $_.Exception.Response
    if (-not $resp) { throw }
    $body = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
    return @{ Status = [int]$resp.StatusCode; Body = $body }
  }
}
$auth = @{}
if ($env:SUPPORT_API_KEY) { $auth['X-API-Key'] = $env:SUPPORT_API_KEY }
function Msg($o) { ConvertTo-Json $o -Compress }
$email = "test+$(Get-Date -Format 'yyyyMMddHHmmss')@example.com"

# Right after an n8n restart /healthz answers before the webhooks are registered (404). Wait for them.
for ($i = 0; $i -lt 60 -and (Call Get "$base/customer-feedback").Status -eq 404; $i++) { Start-Sleep 1 }

Write-Host '== Input validation =='
$r = Call Post "$base/support-message" (Msg @{ name = 'Jane'; email = 'not-an-email'; message = 'hello' }) $auth
Check 'invalid email -> 400' ($r.Status -eq 400) "got $($r.Status) $($r.Body)"
$r = Call Post "$base/support-message" (Msg @{ name = 'Jane'; email = $email }) $auth
Check 'missing message -> 400' ($r.Status -eq 400) "got $($r.Status)"
$r = Call Post "$base/support-message" (Msg @{ email = $email; message = ('x' * 2001) }) $auth
Check 'message over 2000 chars -> 400' ($r.Status -eq 400) "got $($r.Status)"
if ($env:SUPPORT_API_KEY) {
  $r = Call Post "$base/support-message" (Msg @{ email = $email; message = 'hello' }) @{}
  Check 'missing X-API-Key -> 401' ($r.Status -eq 401) "got $($r.Status)"
} else { Write-Host '  SKIP  API key checks (SUPPORT_API_KEY is not set in .env)' -ForegroundColor Yellow }
$r = Call Get "$base/support-message"
Check 'GET on support-message -> 404 (POST only)' ($r.Status -eq 404) "got $($r.Status)"

Write-Host "== Support message: $Message =="
$r = Call Post "$base/support-message" (Msg @{ name = 'Jane'; email = $email; message = $Message }) $auth
Check 'valid message -> 202' ($r.Status -eq 202) "got $($r.Status) $($r.Body)"
$ticket = $null
if ($r.Status -eq 202) { $ticket = ($r.Body | ConvertFrom-Json).ticket_id }
Check 'response contains a ticket_id' ($ticket -match '^SUP-\d{4}-\d{6}$') "ticket_id='$ticket'"
if ($ticket -notmatch '^SUP-\d{4}-\d{6}$') { Write-Host "Cannot continue without a ticket." -ForegroundColor Red; exit 1 }

Write-Host "Waiting up to $TimeoutSec s for $ticket to be saved with its sentiment..."
$deadline = (Get-Date).AddSeconds($TimeoutSec); $row = $null
while ((Get-Date) -lt $deadline) {
  Start-Sleep 5
  $row = Query "select intent, sentiment, left(ai_response, 100), customer_email, status from support_requests where ticket_id = '$ticket'"
  if ($row -and ($row -split '\|')[1]) { break }
}
Check 'ticket saved in PostgreSQL' ([bool]$row) 'no row - check: docker compose logs n8n'
if ($row) {
  $c = $row -split '\|'
  Check 'intent detected' ([bool]$c[0]) "intent='$($c[0])'"
  Check 'sentiment saved' ($c[1] -in 'Positive', 'Neutral', 'Negative') "sentiment='$($c[1])'"
  Check 'AI response saved' ([bool]$c[2])
  Check 'email stored lower-case' ($c[3] -ceq $email.ToLower())
  Check 'ticket status is answered' ($c[4] -eq 'answered') "status='$($c[4])'"
  Write-Host "  Saved: $row"
}

Write-Host '== Feedback =='
$r = Call Get "$base/customer-feedback?ticket_id=$ticket&rating=good&feedback=Tested%20by%20script"
Check 'good rating -> 200 thank-you page' ($r.Status -eq 200 -and $r.Body -match 'Thank You for Your Feedback') "got $($r.Status)"
Check 'feedback row saved with comment' ((Query "select feedback from customer_feedback where ticket_id = '$ticket' and rating = 'good' order by id desc limit 1") -eq 'Tested by script')
$r = Call Get "$base/customer-feedback?ticket_id=$ticket&rating=bad"
Check 'bad rating -> 200' ($r.Status -eq 200) "got $($r.Status)"
$r = Call Get "$base/customer-feedback?ticket_id=$ticket&rating=amazing"
Check 'unknown rating -> 400' ($r.Status -eq 400) "got $($r.Status)"
$r = Call Get "$base/customer-feedback?rating=good"
Check 'missing ticket_id -> 400' ($r.Status -eq 400) "got $($r.Status)"
$r = Call Get "$base/customer-feedback?ticket_id=SUP-2026-999999&rating=good"
Check 'unknown ticket -> 404' ($r.Status -eq 404) "got $($r.Status)"
Check 'nothing saved for unknown ticket' ((Query "select count(*) from customer_feedback where ticket_id = 'SUP-2026-999999'") -eq '0')

if ($script:failed) { Write-Host "`n$script:failed check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "`nAll checks passed" -ForegroundColor Green
