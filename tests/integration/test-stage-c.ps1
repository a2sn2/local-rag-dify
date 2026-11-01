# ==============================================================================
# Script: test-stage-c.ps1
# Description: Stage C Acceptance Tests — Ollama Networking, Plugin & Model Runtime Integration
# Target: Windows 11 / Docker Desktop / Ollama Native / Dify v1.18.0
# Author: a2sn2
# Date: 2026-11-01
# ==============================================================================

[CmdletBinding()]
param(
    [string]$WorkspaceDir = "C:\Users\hassa\local-rag",
    [string]$TenantId = "b30587b8-f547-461e-bfdf-59e8cb4b1bbb"
)

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Stage C Acceptance Tests: Ollama & Embedding Integration" -ForegroundColor Cyan
Write-Host "  Time: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))     " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$testResults = [ordered]@{}

# ------------------------------------------------------------------------------
# 1. Native Windows Ollama Service
# ------------------------------------------------------------------------------
Write-Host "`n[1/6] Testing Native Ollama Service on localhost:11434..." -ForegroundColor Yellow
try {
    $tagsResp = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -Method Get -TimeoutSec 10
    $modelNames = $tagsResp.models | ForEach-Object { $_.name }
    Write-Host "  Found Ollama Models: $($modelNames -join ', ')" -ForegroundColor Gray

    $hasQwen = $modelNames -contains "qwen3.5:4b"
    $hasBge = ($modelNames -contains "bge-m3:latest") -or ($modelNames -contains "bge-m3")

    if (-not $hasQwen) { throw "Model 'qwen3.5:4b' is missing from Ollama." }
    if (-not $hasBge) { throw "Model 'bge-m3:latest' is missing from Ollama." }

    Write-Host "  [PASS] Ollama service is operational with qwen3.5:4b and bge-m3." -ForegroundColor Green
    $testResults["1_Ollama_Service"] = "PASS"
} catch {
    Write-Host "  [FAIL] Ollama service check failed: $_" -ForegroundColor Red
    $testResults["1_Ollama_Service"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# 2. Container-to-Host Gateway Networking
# ------------------------------------------------------------------------------
Write-Host "`n[2/6] Testing Container-to-Host Networking (host.docker.internal)..." -ForegroundColor Yellow
try {
    $apiCurl = docker exec dify-api-1 curl -s -m 5 "http://host.docker.internal:11434/api/tags"
    if (-not $apiCurl -or $apiCurl -notmatch "qwen3.5:4b") {
        throw "dify-api-1 failed to retrieve models from host.docker.internal:11434"
    }

    $daemonCurl = docker exec dify-plugin_daemon-1 curl -s -m 5 "http://host.docker.internal:11434/api/tags"
    if (-not $daemonCurl -or $daemonCurl -notmatch "bge-m3") {
        throw "dify-plugin_daemon-1 failed to retrieve models from host.docker.internal:11434"
    }

    Write-Host "  [PASS] Both dify-api and dify-plugin_daemon query host.docker.internal:11434 successfully." -ForegroundColor Green
    $testResults["2_Container_Gateway_Networking"] = "PASS"
} catch {
    Write-Host "  [FAIL] Container networking check failed: $_" -ForegroundColor Red
    $testResults["2_Container_Gateway_Networking"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# 3. In-Container Dify Model Runtime Integration (Embedding + LLM)
# ------------------------------------------------------------------------------
Write-Host "`n[3/6] Running Dify In-Container Acceptance Tests (verify_stage_c.py)..." -ForegroundColor Yellow
try {
    $verifyPyPath = Join-Path $WorkspaceDir "tests\integration\verify_stage_c.py"
    if (-not (Test-Path $verifyPyPath)) {
        throw "Verification script not found at $verifyPyPath"
    }

    docker cp $verifyPyPath "dify-api-1:/tmp/verify_stage_c.py"
    $execOutput = docker exec dify-api-1 python /tmp/verify_stage_c.py $TenantId

    Write-Host ($execOutput -join "`n") -ForegroundColor Gray

    $outString = $execOutput -join "`n"
    if ($outString -notmatch "ALL IN-CONTAINER STAGE C ACCEPTANCE CHECKS PASSED") {
        throw "In-container checks failed: $outString"
    }

    Write-Host "  [PASS] Dify model provider, bge-m3 embedding, and qwen3.5:4b chat tests passed completely." -ForegroundColor Green
    $testResults["3_Dify_Model_Runtime"] = "PASS"
} catch {
    Write-Host "  [FAIL] In-container acceptance tests failed: $_" -ForegroundColor Red
    $testResults["3_Dify_Model_Runtime"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# 4. GPU VRAM & Temperature Verification
# ------------------------------------------------------------------------------
Write-Host "`n[4/6] Auditing GPU VRAM and System Memory Overhead..." -ForegroundColor Yellow
try {
    $smiOut = nvidia-smi --query-gpu=memory.used,memory.total,temperature.gpu,utilization.gpu --format=csv,noheader,nounits
    $parts = $smiOut -split ",\s*"
    $usedVram = [int]$parts[0]
    $totalVram = [int]$parts[1]
    $gpuTemp = $parts[2]
    $gpuUtil = $parts[3]

    Write-Host "  VRAM Usage: $usedVram MiB / $totalVram MiB (Temp: $gpuTemp C, Util: $gpuUtil %)" -ForegroundColor Gray

    $freeVram = $totalVram - $usedVram
    $minSafeHeadroomMiB = 1200

    if ($freeVram -lt $minSafeHeadroomMiB) {
        throw "VRAM headroom ($freeVram MiB) is below minimum safe threshold ($minSafeHeadroomMiB MiB). Check model concurrency."
    }

    Write-Host "  [PASS] GPU VRAM within safe limits (Used: $usedVram MiB, Free Headroom: $freeVram MiB >= $minSafeHeadroomMiB MiB)." -ForegroundColor Green
    $testResults["4_GPU_Memory_Boundaries"] = "PASS ($usedVram / $totalVram MiB, Headroom: $freeVram MiB)"
} catch {
    Write-Host "  [FAIL] GPU VRAM safety threshold failed: $_" -ForegroundColor Red
    $testResults["4_GPU_Memory_Boundaries"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# 5. Dify Container Port Containment Audit
# ------------------------------------------------------------------------------
Write-Host "`n[5/6] Auditing Dify Port Containment (Strict Loopback Allowlist)..." -ForegroundColor Yellow
try {
    $portsRaw = docker ps --format "{{.Names}}: {{.Ports}}"
    if ($LASTEXITCODE -ne 0) { throw "docker ps command failed with exit code $LASTEXITCODE" }

    $lines = $portsRaw -split "`n"
    $allowedPatterns = @(
        '^dify-nginx-1:\s*127\.0\.0\.1:80->80/tcp,\s*127\.0\.0\.1:443->443/tcp$',
        '^dify-plugin_daemon-1:\s*127\.0\.0\.1:5003->5003/tcp$'
    )

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        # Extract name and ports
        if ($trimmed -match '^([^:]+):\s*(.*)$') {
            $cName = $matches[1].Trim()
            $cPorts = $matches[2].Trim()

            # If container has host-published ports (contains ->)
            if ($cPorts -match '->') {
                $isAllowed = $false
                foreach ($pattern in $allowedPatterns) {
                    if ($trimmed -match $pattern) {
                        $isAllowed = $true
                        break
                    }
                }
                if (-not $isAllowed) {
                    throw "Unauthorized host port mapping on $cName: '$cPorts'. Must match explicit loopback allowlist."
                }
            }
        }
    }

    Write-Host "  [PASS] All published container ports strictly match loopback allowlist (127.0.0.1:80, 443, 5003)." -ForegroundColor Green
    $testResults["5_Port_Containment"] = "PASS"
} catch {
    Write-Host "  [FAIL] Port containment audit failed: $_" -ForegroundColor Red
    $testResults["5_Port_Containment"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# 6. Dify System Health & Gateway Endpoints
# ------------------------------------------------------------------------------
Write-Host "`n[6/6] Verifying Dify API Health and Web Gateway..." -ForegroundColor Yellow
try {
    # 1. Internal API healthcheck
    $apiHealth = docker exec dify-api-1 curl -s http://localhost:5001/health
    if ($apiHealth -notmatch '"status":\s*"ok"') {
        throw "Internal API health failed: $apiHealth"
    }

    # 2. External Web Gateway
    $httpCode = curl.exe -s -m 10 -o NUL -w "%{http_code}" "http://127.0.0.1/install"
    if ($httpCode -ne "200") {
        throw "Gateway returned non-200 status: $httpCode"
    }

    Write-Host "  [PASS] Dify internal API (/health) and external Web Gateway (http://127.0.0.1/install) are fully operational." -ForegroundColor Green
    $testResults["6_Dify_Health_Endpoints"] = "PASS"
} catch {
    Write-Host "  [FAIL] Dify health check failed: $_" -ForegroundColor Red
    $testResults["6_Dify_Health_Endpoints"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# Summary Report
# ------------------------------------------------------------------------------
Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  Stage C Acceptance Test Summary                         " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
foreach ($item in $testResults.GetEnumerator()) {
    Write-Host "  $($item.Key): $($item.Value)" -ForegroundColor Green
}
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Stage C Verification Completed Successfully!`n" -ForegroundColor Green
