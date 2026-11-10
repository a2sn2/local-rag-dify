<#
.SYNOPSIS
    Applies the Baseera Docs v1.3 universal local PDF extraction patch inside dify-api-1 and restarts the API container.
.DESCRIPTION
    Patches graphon's document_extractor node inside dify-api-1 to fix Arabic RTL ligature fragmentation,
    add Page-1 visual letterhead/footer OCR fallback via 100% local Ollama qwen3.5:4b, deduplicate
    repeated multi-page headers/footers, attach page citations [صفحة X من N], and prepend file names.
    Re-run safely if dify-api-1 is recreated from image. Idempotent.
#>
$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$PatchPy = Join-Path $PSScriptRoot "patch_dify_pdf_extractor.py"

if (-not (Test-Path $PatchPy)) {
    throw "Missing patch script: $PatchPy"
}

Write-Host "[1/3] Copying universal PDF extractor patch into dify-api-1..."
docker cp $PatchPy dify-api-1:/tmp/patch_dify_pdf_extractor.py | Out-Null

Write-Host "[2/3] Applying idempotent patch inside dify-api-1..."
docker exec -i dify-api-1 /app/api/.venv/bin/python /tmp/patch_dify_pdf_extractor.py

Write-Host "[3/3] Restarting dify-api-1 and waiting for healthy status..."
docker restart dify-api-1 | Out-Null
for ($i = 0; $i -lt 30; $i++) {
    $st = docker inspect -f '{{.State.Health.Status}}' dify-api-1 2>$null
    if ($st -eq 'healthy') {
        Write-Host "dify-api-1 is healthy with v1.3 universal PDF extractor active."
        exit 0
    }
    Start-Sleep -Seconds 2
}
throw "Timed out waiting for dify-api-1 to become healthy after restart."

