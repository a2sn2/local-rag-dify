# ==============================================================================
# Script: test-service-recovery.ps1
# Description: Stage E Service Resilience, Restart & Recovery Verification Test
# Validates: Persistence of OLLAMA_MAX_LOADED_MODELS=1 across process restarts,
#            Dify microservices container restarts, and post-recovery inference.
# Target: Windows 11 / Docker Desktop / Ollama Native
# Author: a2sn2
# Date: 2026-11-01
# ==============================================================================

[CmdletBinding()]
param(
    [string]$WorkspaceDir = "C:\Users\hassa\local-rag"
)

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Stage E: Service Resilience & Restart Recovery Test      " -ForegroundColor Cyan
Write-Host "  Time: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))     " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$recoveryResults = [ordered]@{}

# ------------------------------------------------------------------------------
# 1. Environment Variable Persistence Check
# ------------------------------------------------------------------------------
Write-Host "`n[1/5] Checking Persistent OLLAMA_MAX_LOADED_MODELS in Registry..." -ForegroundColor Yellow
$regVal = (Get-ItemProperty -Path "HKCU:\Environment" -Name "OLLAMA_MAX_LOADED_MODELS" -ErrorAction SilentlyContinue).OLLAMA_MAX_LOADED_MODELS
if ($regVal -ne "1") {
    throw "HKCU:\Environment:OLLAMA_MAX_LOADED_MODELS is '$regVal' (expected '1')."
}
Write-Host "  [OK] Persistent OLLAMA_MAX_LOADED_MODELS=1 confirmed in Windows User Registry." -ForegroundColor Green
$recoveryResults["1_Registry_Persistence"] = "PASS (Value: 1)"

# ------------------------------------------------------------------------------
# 2. Ollama Process Termination and Restart
# ------------------------------------------------------------------------------
Write-Host "`n[2/5] Testing Native Ollama Daemon Restart & Model Re-registration..." -ForegroundColor Yellow
try {
    $ollamaProc = Get-Process ollama -ErrorAction SilentlyContinue
    if ($ollamaProc) {
        Write-Host "  Stopping existing Ollama process (PID: $($ollamaProc.Id))..." -ForegroundColor Gray
        Stop-Process -Id $ollamaProc.Id -Force
        Start-Sleep -Seconds 3
    }

    # Verify process stopped
    $stoppedProc = Get-Process ollama -ErrorAction SilentlyContinue
    if ($stoppedProc) { throw "Failed to stop Ollama process." }
    Write-Host "  [OK] Ollama process successfully terminated." -ForegroundColor Gray

    # Restart Ollama daemon with persistent environment variable
    $env:OLLAMA_MAX_LOADED_MODELS = "1"
    $env:OLLAMA_NUM_PARALLEL = "1"
    $ollamaExe = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
    if (-not (Test-Path $ollamaExe)) {
        throw "Ollama executable not found at '$ollamaExe'."
    }

    Write-Host "  Starting Ollama daemon from '$ollamaExe'..." -ForegroundColor Gray
    Start-Process -FilePath $ollamaExe -ArgumentList "serve" -WindowStyle Hidden
    
    # Wait for Ollama service readiness
    $ollamaReady = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        try {
            $tags = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -Method Get -TimeoutSec 3
            if ($tags.models.Count -ge 2) {
                $ollamaReady = $true
                break
            }
        } catch {}
    }

    if (-not $ollamaReady) {
        throw "Ollama service failed to recover after restart."
    }

    $newProc = Get-Process ollama | Select-Object -First 1
    Write-Host "  [OK] Ollama recovered successfully (PID: $($newProc.Id)) with required models." -ForegroundColor Green
    $recoveryResults["2_Ollama_Restart_Recovery"] = "PASS (PID: $($newProc.Id))"
} catch {
    Write-Host "  [FAIL] Ollama restart failed: $_" -ForegroundColor Red
    $recoveryResults["2_Ollama_Restart_Recovery"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# 3. Dify Microservices Container Restart
# ------------------------------------------------------------------------------
Write-Host "`n[3/5] Testing Dify Core Containers Restart (Nginx, API, Plugin Daemon)..." -ForegroundColor Yellow
try {
    Write-Host "  Restarting containers: dify-nginx-1, dify-api-1, dify-plugin_daemon-1..." -ForegroundColor Gray
    docker restart dify-nginx-1 dify-api-1 dify-plugin_daemon-1 | Out-Null

    # Wait for dify-api-1 healthcheck
    Write-Host "  Waiting for dify-api-1 healthcheck..." -ForegroundColor Gray
    $apiHealthy = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Seconds 1
        $health = docker inspect --format="{{.State.Health.Status}}" dify-api-1 2>&1
        if ($health -eq "healthy") {
            $apiHealthy = $true
            break
        }
    }

    if (-not $apiHealthy) {
        throw "dify-api-1 failed to achieve healthy status within 40 seconds."
    }
    Write-Host "  [OK] dify-api-1 returned to healthy status." -ForegroundColor Green
    $recoveryResults["3_Dify_Containers_Restart"] = "PASS (API Healthy)"
} catch {
    Write-Host "  [FAIL] Dify containers restart failed: $_" -ForegroundColor Red
    $recoveryResults["3_Dify_Containers_Restart"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# 4. Web Gateway & Database Integrity Verification
# ------------------------------------------------------------------------------
Write-Host "`n[4/5] Verifying Web Gateway and Database Migration Integrity..." -ForegroundColor Yellow
try {
    $webResp = Invoke-WebRequest -Uri "http://127.0.0.1/apps" -UseBasicParsing -TimeoutSec 15
    if ($webResp.StatusCode -ne 200) {
        throw "Web gateway returned HTTP $($webResp.StatusCode)"
    }
    Write-Host "  [OK] Nginx Web Gateway operational (HTTP 200 OK)." -ForegroundColor Green

    $pyDbCheck = @'
import sys; sys.path.insert(0, '/app/api')
import app; from extensions.ext_database import db; from models.dataset import Dataset
_, a = app.create_app()
with a.app_context():
    cnt = db.session.query(Dataset).count()
    print('DB_OK:DATASETS=' + str(cnt))
'@
    $dbStatus = docker exec dify-api-1 python -c $pyDbCheck 2>&1
    if ($dbStatus -notmatch "DB_OK:DATASETS=[1-9]") {
        throw "Database integrity check failed: $dbStatus"
    }
    Write-Host "  [OK] Database operational with existing datasets ($($matches[0]))." -ForegroundColor Green
    $recoveryResults["4_Database_Integrity"] = "PASS"
} catch {
    Write-Host "  [FAIL] Gateway/Database verification failed: $_" -ForegroundColor Red
    $recoveryResults["4_Database_Integrity"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# 5. Post-Recovery End-to-End Inference Verification
# ------------------------------------------------------------------------------
Write-Host "`n[5/5] Executing Post-Recovery End-to-End Inference Test..." -ForegroundColor Yellow
try {
    $pyInferCheck = @'
import sys; sys.path.insert(0, '/app/api')
import app, requests
from extensions.ext_database import db
from models.model import App, ApiToken
from models.enums import ApiTokenType

_, a = app.create_app()
with a.app_context():
    app_model = db.session.query(App).filter(App.name == 'Local Bilingual RAG Assistant').first()
    tok = db.session.query(ApiToken).filter(ApiToken.app_id == app_model.id, ApiToken.type == ApiTokenType.APP).first().token
headers = {'Authorization': 'Bearer ' + tok, 'Content-Type': 'application/json'}
payload = {'inputs': {}, 'query': 'كم عدد محطات التحويل الرقمية الذكية المستهدفة في مبادرة أتمتة الشبكة الكهربائية الوطنية؟', 'response_mode': 'blocking', 'user': 'recovery-test'}
resp = requests.post('http://127.0.0.1:5001/v1/chat-messages', json=payload, headers=headers, timeout=60)
print('STATUS:' + str(resp.status_code) + '|ANS:' + resp.json().get('answer', '')[:60])
'@
    $inferOut = docker exec dify-api-1 python -c $pyInferCheck 2>&1
    Write-Host "  Inference Output: $inferOut" -ForegroundColor Gray

    if ($inferOut -notmatch "STATUS:200") {
        throw "Post-recovery inference failed: $inferOut"
    }
    Write-Host "  [OK] Post-recovery RAG inference operational and returning HTTP 200." -ForegroundColor Green
    $recoveryResults["5_Post_Recovery_Inference"] = "PASS"
} catch {
    Write-Host "  [FAIL] Post-recovery inference failed: $_" -ForegroundColor Red
    $recoveryResults["5_Post_Recovery_Inference"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# Summary Report
# ------------------------------------------------------------------------------
Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  Stage E Service Recovery Test Summary                   " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
foreach ($item in $recoveryResults.GetEnumerator()) {
    Write-Host "  $($item.Key): $($item.Value)" -ForegroundColor Green
}
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Service Recovery & Restart Verification Completed Successfully!`n" -ForegroundColor Green

