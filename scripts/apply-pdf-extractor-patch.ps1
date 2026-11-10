<#
.SYNOPSIS
    Regenerates and deploys the Baseera Docs v1.3.1 universal local PDF extraction patch across BOTH dify-api-1 and dify-worker-1.
.DESCRIPTION
    1. Builds canonical patched DocumentExtractorNode source from the pristine Dify v1.18.0 baseline into:
       docker/dify/patches/document_extractor_node.py (bind-mounted read-only into api & worker via docker-compose.override.yaml).
    2. If api/worker already have the bind mount active, restarts them to reload Python workers cleanly.
       Otherwise recreates api & worker using docker-compose.override.yaml so the patch persists across container recreation.
    Idempotent and safe: does NOT modify networks, firewall rules, Postgres data, or JAIB dify-web-1.
#>
$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$PatchPy = Join-Path $PSScriptRoot "patch_dify_pdf_extractor.py"
$CanonicalOut = Join-Path $RepoRoot "docker\dify\patches\document_extractor_node.py"
$ComposeDir = Join-Path $RepoRoot "docker\dify"

if (-not (Test-Path $PatchPy)) {
    throw "Missing patch script: $PatchPy"
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $CanonicalOut) | Out-Null

Write-Host "[1/4] Fetching pristine v1.18.0 baseline node.py from local image/container..."
docker cp $PatchPy dify-api-1:/tmp/patch_dify_pdf_extractor.py | Out-Null
$hasOrig = (docker exec dify-api-1 sh -c "test -f /app/api/.venv/lib/python3.13/site-packages/graphon/nodes/document_extractor/node.py.orig_v1_18 && echo yes || echo no").Trim()
if ($hasOrig -eq "yes") {
    $srcInside = "/app/api/.venv/lib/python3.13/site-packages/graphon/nodes/document_extractor/node.py.orig_v1_18"
} else {
    $isPatched = [int](docker exec dify-api-1 grep -c "build_staged_long_document_digest\|_apply_local_window_guard" /app/api/.venv/lib/python3.13/site-packages/graphon/nodes/document_extractor/node.py 2>$null)
    if ($isPatched -eq 0) {
        $srcInside = "/app/api/.venv/lib/python3.13/site-packages/graphon/nodes/document_extractor/node.py"
    } else {
        $tmpOrig = Join-Path $env:TEMP "dify_node_orig_v1_18.py"
        $cid = (docker create --entrypoint sh langgenius/dify-api:1.18.0 -c "true").Trim()
        if ($LASTEXITCODE -ne 0 -or -not $cid) { throw "Failed creating temp container from langgenius/dify-api:1.18.0" }
        try {
            docker cp "${cid}:/app/api/.venv/lib/python3.13/site-packages/graphon/nodes/document_extractor/node.py" $tmpOrig | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Failed extracting pristine node.py from image" }
        } finally {
            docker rm $cid | Out-Null
        }
        docker cp $tmpOrig dify-api-1:/tmp/orig_v1_18_node.py | Out-Null
        Remove-Item $tmpOrig -ErrorAction SilentlyContinue
        $srcInside = "/tmp/orig_v1_18_node.py"
    }
}

Write-Host "[2/4] Generating canonical v1.3.1 document_extractor_node.py..."
docker exec -i dify-api-1 /app/api/.venv/bin/python /tmp/patch_dify_pdf_extractor.py --source $srcInside --output /tmp/document_extractor_node.py
if ($LASTEXITCODE -ne 0) { throw "patch_dify_pdf_extractor.py failed inside dify-api-1" }
docker exec -i dify-api-1 /app/api/.venv/bin/python -m py_compile /tmp/document_extractor_node.py
if ($LASTEXITCODE -ne 0) { throw "py_compile failed on generated document_extractor_node.py" }
docker cp dify-api-1:/tmp/document_extractor_node.py $CanonicalOut | Out-Null
if ($LASTEXITCODE -ne 0) { throw "docker cp failed copying generated document_extractor_node.py" }

# Ensure host file stays pure UTF-8 LF for clean Linux container bind-mount
$txt = [System.IO.File]::ReadAllText($CanonicalOut, [System.Text.UTF8Encoding]::new($false)).Replace("`r`n", "`n")
[System.IO.File]::WriteAllText($CanonicalOut, $txt, [System.Text.UTF8Encoding]::new($false))

Write-Host "[3/4] Ensuring api and worker mount canonical patch via docker-compose.override.yaml..."
Push-Location $ComposeDir
try {
    docker compose -f docker-compose.yaml -f docker-compose.override.yaml up -d --no-deps --force-recreate api worker | Out-Null
} finally {
    Pop-Location
}

Write-Host "[4/4] Verifying identical v1.3.1 extractor hash and health in dify-api-1 and dify-worker-1..."
for ($i = 0; $i -lt 45; $i++) {
    $st = docker inspect -f '{{.State.Health.Status}}' dify-api-1 2>$null
    if ($st -eq 'healthy') { break }
    Start-Sleep -Seconds 2
}
$stFinal = docker inspect -f '{{.State.Health.Status}}' dify-api-1 2>$null
if ($stFinal -ne 'healthy') { throw "dify-api-1 failed health check after recreation (status=$stFinal)" }

$hApi = (docker exec dify-api-1 md5sum /app/api/.venv/lib/python3.13/site-packages/graphon/nodes/document_extractor/node.py).Split()[0]
$hWrk = (docker exec dify-worker-1 md5sum /app/api/.venv/lib/python3.13/site-packages/graphon/nodes/document_extractor/node.py).Split()[0]
$mApi = (docker exec dify-api-1 grep -c "_build_staged_long_document_digest" /app/api/.venv/lib/python3.13/site-packages/graphon/nodes/document_extractor/node.py).Trim()
$mWrk = (docker exec dify-worker-1 grep -c "_build_staged_long_document_digest" /app/api/.venv/lib/python3.13/site-packages/graphon/nodes/document_extractor/node.py).Trim()
if ($hApi -ne $hWrk -or [int]$mApi -lt 1 -or [int]$mWrk -lt 1) {
    throw "Verification mismatch: api=($hApi,$mApi) worker=($hWrk,$mWrk)"
}
Write-Host "SUCCESS: dify-api-1 ($hApi) and dify-worker-1 ($hWrk) are BOTH running identical v1.3.1 DocumentExtractorNode (persistent mount)."
