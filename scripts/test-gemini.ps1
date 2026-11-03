# Verifies the Gemini key via its OpenAI-compatible endpoint: model list, one chat completion,
# one embedding (1536 dims expected, matching the Qdrant collection).
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\load-env.ps1"
if (-not $env:GEMINI_API_KEY) { throw 'GEMINI_API_KEY missing (.env)' }
$base = if ($env:GEMINI_BASE_URL) { $env:GEMINI_BASE_URL } else { 'https://generativelanguage.googleapis.com/v1beta/openai' }
$chat = if ($env:GEMINI_CHAT_MODEL) { $env:GEMINI_CHAT_MODEL } else { 'gemini-3.1-flash-lite' }
$emb = if ($env:GEMINI_EMBEDDING_MODEL) { $env:GEMINI_EMBEDDING_MODEL } else { 'gemini-embedding-001' }
$h = @{ Authorization = "Bearer $env:GEMINI_API_KEY" }

$models = Invoke-RestMethod "$base/models" -Headers $h
"Key OK, $($models.data.Count) models visible"
$fallback = if ($env:GEMINI_FALLBACK_MODEL) { $env:GEMINI_FALLBACK_MODEL } else { 'gemini-3.5-flash-lite' }
# Mirrors the workflow: retry temporary errors (503/429), then switch to the fallback model.
$r = $null
foreach ($model in @($chat, $chat, $fallback)) {
  try {
    $r = Invoke-RestMethod -Method Post "$base/chat/completions" -Headers $h -ContentType 'application/json' `
      -Body (@{ model = $model; messages = @(@{ role = 'user'; content = 'Reply with the word OK.' }) } | ConvertTo-Json -Depth 5)
    $chat = $model; break
  } catch {
    Write-Warning "Chat model '$model' failed: $($_.Exception.Message)"
    Start-Sleep -Seconds 3
  }
}
if (-not $r) { throw 'Chat failed on all models - check GEMINI_CHAT_MODEL / GEMINI_FALLBACK_MODEL in .env' }
"Chat ($chat): " + $r.choices[0].message.content
$e = Invoke-RestMethod -Method Post "$base/embeddings" -Headers $h -ContentType 'application/json' `
  -Body (@{ model = $emb; input = 'hello'; dimensions = 1536 } | ConvertTo-Json)
"Embedding ($emb): $($e.data[0].embedding.Count) dimensions"
