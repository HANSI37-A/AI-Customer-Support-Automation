# Embeds knowledge_base/faq.txt (one point per blank-line-separated block) via Gemini (OpenAI-compatible endpoint)
# and upserts it into the Qdrant collection support_docs.
# Requires GEMINI_API_KEY in .env.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\load-env.ps1"
if (-not $env:GEMINI_API_KEY) { throw 'GEMINI_API_KEY missing (.env)' }
$orBase = if ($env:GEMINI_BASE_URL) { $env:GEMINI_BASE_URL } else { 'https://generativelanguage.googleapis.com/v1beta/openai' }
$embModel = if ($env:GEMINI_EMBEDDING_MODEL) { $env:GEMINI_EMBEDDING_MODEL } else { 'gemini-embedding-001' }
$root = Split-Path $PSScriptRoot -Parent
$qdrantPort = if ($env:QDRANT_HOST_PORT) { $env:QDRANT_HOST_PORT } else { 6333 }
$base = "http://localhost:$qdrantPort/collections/support_docs"

$docs = (Get-Content (Join-Path $root 'knowledge_base\faq.txt') -Raw -Encoding UTF8) -split '(\r?\n){2,}' |
  ForEach-Object { $_.Trim() } | Where-Object { $_ -match '\S' }

$points = @(); $id = 1
foreach ($d in $docs) {
  $body = ConvertTo-Json @{ model = $embModel; input = $d; dimensions = 1536 } -Compress
  $r = Invoke-RestMethod -Method Post "$orBase/embeddings" -ContentType 'application/json; charset=utf-8' `
    -Headers @{ Authorization = "Bearer $env:GEMINI_API_KEY" } -Body ([Text.Encoding]::UTF8.GetBytes($body))
  $points += @{ id = $id++; vector = $r.data[0].embedding; payload = @{ text = $d } }
}
$put = ConvertTo-Json @{ points = $points } -Depth 6 -Compress
Invoke-RestMethod -Method Put "$base/points?wait=true" -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($put)) | Out-Null
Write-Host ("Upserted {0} documents. Points in collection: {1}" -f $points.Count, (Invoke-RestMethod $base).result.points_count)
