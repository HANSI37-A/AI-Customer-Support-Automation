# Imports every template in n8n\backup\workflows into n8n as INACTIVE workflows (browse them in the UI).
# Imports one file at a time (n8n aborts a whole bulk import on a single bad file), so it takes ~15-20 min.
# Known to fail on import (skipped): Bitrix24 Chatbot..., Create dynamic Twitter profile banner,
# Custom LangChain agent written in JavaScript, OpenAI-powered tweet generator, V1_Local_RAG_AI_Agent.
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$n8n = (docker compose ps -q n8n)
if (-not $n8n) { throw 'n8n container is not running (docker compose up -d)' }
docker exec -u root $n8n rm -rf /tmp/templates
docker cp "n8n\backup\workflows" "${n8n}:/tmp/templates"
docker exec -u root $n8n chmod -R a+rX /tmp/templates
docker exec $n8n sh -c 'cd /tmp/templates; for f in *.json; do rm -rf /tmp/one; mkdir /tmp/one; cp "$f" /tmp/one/; n8n import:workflow --separate --input=/tmp/one 2>&1 | grep -q Successfully || echo "FAILED: $f"; done'
docker exec -u root $n8n rm -rf /tmp/templates /tmp/one
docker exec $n8n n8n list:workflow | Measure-Object -Line | ForEach-Object { "Workflows in n8n: $($_.Lines)" }
