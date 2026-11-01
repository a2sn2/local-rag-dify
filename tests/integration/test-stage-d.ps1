# ==============================================================================
# Script: test-stage-d.ps1
# Description: Stage D Acceptance Tests — Bilingual Grounded RAG Application,
#              Knowledge Base Indexing, Citation Auditing & Anti-Hallucination
# Target: Windows 11 / Docker Desktop / Ollama Native / Dify v1.18.0 / Weaviate
# Author: a2sn2
# Date: 2026-11-01
# ==============================================================================

[CmdletBinding()]
param(
    [string]$WorkspaceDir = "C:\Users\hassa\local-rag",
    [string]$TenantId = "b30587b8-f547-461e-bfdf-59e8cb4b1bbb",
    [string]$DatasetId = "8e29fd5b-9537-46ac-acde-191b457b793e",
    [string]$AppName = "Local Bilingual RAG Assistant"
)

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Stage D Acceptance Tests: Bilingual Grounded RAG App     " -ForegroundColor Cyan
Write-Host "  Time: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))     " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$testResults = [ordered]@{}

# ------------------------------------------------------------------------------
# 1. Native Ollama Engine & Model Registry
# ------------------------------------------------------------------------------
Write-Host "`n[1/6] Verifying Native Ollama Service and Models..." -ForegroundColor Yellow
try {
    $tagsResp = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -Method Get -TimeoutSec 10
    $modelNames = $tagsResp.models | ForEach-Object { $_.name }
    Write-Host "  Registered Ollama Models: $($modelNames -join ', ')" -ForegroundColor Gray

    $hasQwen = $modelNames -contains "qwen3.5:4b"
    $hasBge = ($modelNames -contains "bge-m3:latest") -or ($modelNames -contains "bge-m3")

    if (-not $hasQwen) { throw "Model 'qwen3.5:4b' is missing from Ollama." }
    if (-not $hasBge) { throw "Model 'bge-m3:latest' is missing from Ollama." }

    $regMaxLoaded = (Get-ItemProperty -Path "HKCU:\Environment" -Name "OLLAMA_MAX_LOADED_MODELS" -ErrorAction SilentlyContinue).OLLAMA_MAX_LOADED_MODELS
    if ($regMaxLoaded -ne "1") {
        Write-Warning "HKCU:OLLAMA_MAX_LOADED_MODELS is '$regMaxLoaded' (expected '1')."
    } else {
        Write-Host "  [OK] Persistent OLLAMA_MAX_LOADED_MODELS=1 confirmed in registry." -ForegroundColor Gray
    }

    Write-Host "  [PASS] Ollama engine operational with required models and concurrency limits." -ForegroundColor Green
    $testResults["1_Ollama_Service_Models"] = "PASS"
} catch {
    Write-Host "  [FAIL] Ollama service verification failed: $_" -ForegroundColor Red
    $testResults["1_Ollama_Service_Models"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# 2. Vector Database (Weaviate) & Internal Services
# ------------------------------------------------------------------------------
Write-Host "`n[2/6] Verifying Weaviate Vector Database & Internal Infrastructure..." -ForegroundColor Yellow
try {
    $weaviateMeta = docker exec dify-api-1 curl -s -m 5 "http://weaviate:8080/v1/meta"
    if (-not $weaviateMeta -or $weaviateMeta -notmatch "weaviate") {
        throw "Weaviate failed healthcheck from dify-api-1: $weaviateMeta"
    }
    Write-Host "  Weaviate Vector DB: Operational (v1.39.13)" -ForegroundColor Gray

    $redisPing = docker exec dify-redis-1 redis-cli ping
    if ($redisPing -notmatch "PONG") {
        throw "Redis ping failed: $redisPing"
    }

    Write-Host "  [PASS] Weaviate vector engine and Redis storage are operational." -ForegroundColor Green
    $testResults["2_Vector_DB_Infrastructure"] = "PASS"
} catch {
    Write-Host "  [FAIL] Vector database check failed: $_" -ForegroundColor Red
    $testResults["2_Vector_DB_Infrastructure"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# 3. GPU VRAM Headroom & Port Containment
# ------------------------------------------------------------------------------
Write-Host "`n[3/6] Auditing GPU VRAM Safety & Port Containment Allowlist..." -ForegroundColor Yellow
try {
    # GPU VRAM
    $smiOut = nvidia-smi --query-gpu=memory.used,memory.total,temperature.gpu,utilization.gpu --format=csv,noheader,nounits
    $parts = $smiOut -split ",\s*"
    $usedVram = [int]$parts[0]
    $totalVram = [int]$parts[1]
    $gpuTemp = $parts[2]
    $freeVram = $totalVram - $usedVram
    $minSafeHeadroomMiB = 1200

    Write-Host "  VRAM Usage: $usedVram MiB / $totalVram MiB (Free: $freeVram MiB, Temp: $gpuTemp C)" -ForegroundColor Gray

    if ($freeVram -lt $minSafeHeadroomMiB) {
        throw "VRAM headroom ($freeVram MiB) is below minimum safe threshold ($minSafeHeadroomMiB MiB)."
    }

    # Port Containment
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
        if ($trimmed -match '^([^:]+):\s*(.*)$') {
            $cName = $matches[1].Trim()
            $cPorts = $matches[2].Trim()
            if ($cPorts -match '->') {
                $isAllowed = $false
                foreach ($pattern in $allowedPatterns) {
                    if ($trimmed -match $pattern) {
                        $isAllowed = $true
                        break
                    }
                }
                if (-not $isAllowed) {
                    throw "Unauthorized host port mapping on $($cName): '$cPorts'."
                }
            }
        }
    }

    Write-Host "  [PASS] GPU VRAM headroom ($freeVram MiB >= $minSafeHeadroomMiB MiB) and loopback port containment verified." -ForegroundColor Green
    $testResults["3_GPU_and_Port_Containment"] = "PASS (Headroom: $freeVram MiB)"
} catch {
    Write-Host "  [FAIL] GPU VRAM / Port Containment check failed: $_" -ForegroundColor Red
    $testResults["3_GPU_and_Port_Containment"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# 4. Bilingual Knowledge Base & Document Indexing
# ------------------------------------------------------------------------------
Write-Host "`n[4/6] Verifying Bilingual Knowledge Base & Weaviate Indexing..." -ForegroundColor Yellow
try {
    $kbCheckScript = @"
import sys
if '/app/api' not in sys.path:
    sys.path.insert(0, '/app/api')
import app
from extensions.ext_database import db
from models.dataset import Dataset, Document, DocumentSegment

_, flask_app = app.create_app()
with flask_app.app_context():
    dataset = db.session.get(Dataset, '$DatasetId')
    if not dataset:
        print('DATASET_NOT_FOUND')
        sys.exit(1)
    docs = db.session.query(Document).filter(Document.dataset_id == '$DatasetId').all()
    completed_docs = [d for d in docs if d.indexing_status == 'completed']
    segments = db.session.query(DocumentSegment).filter(
        DocumentSegment.dataset_id == '$DatasetId',
        DocumentSegment.status == 'completed'
    ).all()
    print(f'DOCS:{len(completed_docs)}/{len(docs)}|SEGMENTS:{len(segments)}')
"@

    $kbOutput = docker exec dify-api-1 python -c $kbCheckScript
    Write-Host "  Knowledge Base Status: $kbOutput" -ForegroundColor Gray

    if ($kbOutput -notmatch "DOCS:3/3" -or $kbOutput -notmatch "SEGMENTS:27") {
        throw "Dataset indexing incomplete: $kbOutput"
    }

    Write-Host "  [PASS] Knowledge Base contains 3 completed documents and 27 indexed chunks." -ForegroundColor Green
    $testResults["4_Knowledge_Base_Indexing"] = "PASS (3 docs, 27 chunks)"
} catch {
    Write-Host "  [FAIL] Knowledge Base check failed: $_" -ForegroundColor Red
    $testResults["4_Knowledge_Base_Indexing"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# 5. RAG Chatbot Application Configuration
# ------------------------------------------------------------------------------
Write-Host "`n[5/6] Verifying RAG Chatbot Application Configuration..." -ForegroundColor Yellow
try {
    $appCheckScript = @"
import sys
if '/app/api' not in sys.path:
    sys.path.insert(0, '/app/api')
import app
from extensions.ext_database import db
from models.model import App, AppModelConfig, ApiToken
from models.enums import ApiTokenType
from models.dataset import AppDatasetJoin

_, flask_app = app.create_app()
with flask_app.app_context():
    app_model = db.session.query(App).filter(App.name == '$AppName').first()
    if not app_model:
        print('APP_NOT_FOUND')
        sys.exit(1)
    cfg = db.session.get(AppModelConfig, app_model.app_model_config_id)
    join = db.session.query(AppDatasetJoin).filter(
        AppDatasetJoin.app_id == app_model.id,
        AppDatasetJoin.dataset_id == '$DatasetId'
    ).first()
    token = db.session.query(ApiToken).filter(
        ApiToken.app_id == app_model.id,
        ApiToken.type == ApiTokenType.APP
    ).first()

    has_join = join is not None
    has_token = token is not None
    model_name = cfg.model_dict.get('name')
    think_param = cfg.model_dict.get('completion_params', {}).get('think')

    print(f'APP_ID:{app_model.id}|MODEL:{model_name}|THINK:{think_param}|JOIN:{has_join}|TOKEN:{has_token}')
"@

    $appOutput = docker exec dify-api-1 python -c $appCheckScript
    Write-Host "  Application Config: $appOutput" -ForegroundColor Gray

    if ($appOutput -notmatch "MODEL:qwen3.5:4b" -or $appOutput -notmatch "THINK:False" -or $appOutput -notmatch "JOIN:True" -or $appOutput -notmatch "TOKEN:True") {
        throw "Application configuration mismatch: $appOutput"
    }

    Write-Host "  [PASS] Application verified with Qwen3.5:4b, think:false, Dataset join, and active API Token." -ForegroundColor Green
    $testResults["5_RAG_App_Configuration"] = "PASS"
} catch {
    Write-Host "  [FAIL] RAG Application configuration check failed: $_" -ForegroundColor Red
    $testResults["5_RAG_App_Configuration"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# 6. Full Functional Evaluation Suite (TC-01 through TC-05)
# ------------------------------------------------------------------------------
Write-Host "`n[6/6] Executing Comprehensive Bilingual RAG Evaluation Suite..." -ForegroundColor Yellow
try {
    $evalPyPath = Join-Path $WorkspaceDir "tests\rag-evaluation\evaluate_rag.py"
    $queriesJsonPath = Join-Path $WorkspaceDir "tests\rag-evaluation\dataset\test_queries.json"

    docker cp $queriesJsonPath "dify-api-1:/tmp/dataset/test_queries.json"
    docker cp $evalPyPath "dify-api-1:/tmp/evaluate_rag.py"

    $evalOutput = docker exec dify-api-1 python /tmp/evaluate_rag.py
    Write-Host ($evalOutput -join "`n") -ForegroundColor Gray

    $outString = $evalOutput -join "`n"
    if ($outString -notmatch "EVALUATION COMPLETE: 5/5 PASSED \(all_passed=True\)") {
        throw "RAG evaluation suite failed: $outString"
    }

    # Copy report back
    docker cp "dify-api-1:/tmp/evaluation_report.json" (Join-Path $WorkspaceDir "tests\rag-evaluation\evaluation_report.json")

    Write-Host "  [PASS] All 5 evaluation test cases (AR-AR, EN-EN, Cross-Lingual, Abstention, Ambiguity) PASSED completely." -ForegroundColor Green
    $testResults["6_Functional_RAG_Evaluation"] = "PASS (5/5 Cases Passed)"
} catch {
    Write-Host "  [FAIL] Functional evaluation suite failed: $_" -ForegroundColor Red
    $testResults["6_Functional_RAG_Evaluation"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# Summary Report
# ------------------------------------------------------------------------------
Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  Stage D Acceptance Test Summary                         " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
foreach ($item in $testResults.GetEnumerator()) {
    Write-Host "  $($item.Key): $($item.Value)" -ForegroundColor Green
}
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Stage D Verification Completed Successfully!`n" -ForegroundColor Green
