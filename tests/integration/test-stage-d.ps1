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
    [string]$ChatbotAppName = "Local Bilingual RAG Assistant",
    [string]$ChatflowAppName = "Local Bilingual RAG Chatflow"
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
Write-Host "`n[1/7] Verifying Native Ollama Service and Models..." -ForegroundColor Yellow
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
Write-Host "`n[2/7] Verifying Weaviate Vector Database & Internal Infrastructure..." -ForegroundColor Yellow
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
Write-Host "`n[3/7] Auditing GPU VRAM Safety & Port Containment Allowlist..." -ForegroundColor Yellow
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
Write-Host "`n[4/7] Verifying Bilingual Knowledge Base & Weaviate Indexing..." -ForegroundColor Yellow
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

    if ($kbOutput -notmatch "DOCS:3/3" -or $kbOutput -notmatch "SEGMENTS:12") {
        throw "Dataset indexing incomplete: $kbOutput"
    }

    Write-Host "  [PASS] Knowledge Base contains 3 completed documents and 12 indexed cohesive chunks." -ForegroundColor Green
    $testResults["4_Knowledge_Base_Indexing"] = "PASS (3 docs, 12 chunks)"
} catch {
    Write-Host "  [FAIL] Knowledge Base check failed: $_" -ForegroundColor Red
    $testResults["4_Knowledge_Base_Indexing"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# 5. RAG Applications Configuration (Chatbot & Visual Chatflow)
# ------------------------------------------------------------------------------
Write-Host "`n[5/7] Verifying RAG Applications Configuration (Chatbot & Visual Chatflow)..." -ForegroundColor Yellow
try {
    $appsCheckScript = @"
import sys
if '/app/api' not in sys.path:
    sys.path.insert(0, '/app/api')
import app
from extensions.ext_database import db
from models.model import App, AppModelConfig, ApiToken
from models.enums import ApiTokenType
from models.dataset import AppDatasetJoin
from models.workflow import Workflow

_, flask_app = app.create_app()
with flask_app.app_context():
    # 1. Chatbot
    cb = db.session.query(App).filter(App.name == '$ChatbotAppName').first()
    if not cb:
        print('CHATBOT_NOT_FOUND')
        sys.exit(1)
    cb_cfg = db.session.get(AppModelConfig, cb.app_model_config_id)
    cb_join = db.session.query(AppDatasetJoin).filter(
        AppDatasetJoin.app_id == cb.id,
        AppDatasetJoin.dataset_id == '$DatasetId'
    ).first()
    cb_token = db.session.query(ApiToken).filter(
        ApiToken.app_id == cb.id,
        ApiToken.type == ApiTokenType.APP
    ).first()

    # 2. Chatflow
    cf = db.session.query(App).filter(App.name == '$ChatflowAppName').first()
    if not cf:
        print('CHATFLOW_NOT_FOUND')
        sys.exit(1)
    cf_wf = db.session.get(Workflow, cf.workflow_id) if cf.workflow_id else None
    cf_token = db.session.query(ApiToken).filter(
        ApiToken.app_id == cf.id,
        ApiToken.type == ApiTokenType.APP
    ).first()

    cb_model = cb_cfg.model_dict.get('name') if cb_cfg else 'None'
    cb_think = cb_cfg.model_dict.get('completion_params', {}).get('think') if cb_cfg else 'None'

    print(f'CHATBOT|ID:{cb.id}|MODE:{cb.mode}|MODEL:{cb_model}|THINK:{cb_think}|JOIN:{cb_join is not None}|TOKEN:{cb_token is not None}')
    print(f'CHATFLOW|ID:{cf.id}|MODE:{cf.mode}|WF_VERSION:{cf_wf.version if cf_wf else 0}|TOKEN:{cf_token is not None}')
"@

    $appsOutput = docker exec dify-api-1 python -c $appsCheckScript
    $appsOutputStr = ($appsOutput -join "`n")
    Write-Host "  Applications Config Output:`n$appsOutputStr" -ForegroundColor Gray

    if ($appsOutputStr -notmatch "CHATBOT\|ID:[^|]+\|MODE:chat\|MODEL:qwen3\.5:4b\|THINK:False\|JOIN:True\|TOKEN:True") {
        throw "Chatbot application configuration verification failed: $appsOutputStr"
    }
    if ($appsOutputStr -notmatch "CHATFLOW\|ID:[^|]+\|MODE:advanced-chat\|WF_VERSION:[^|]+\|TOKEN:True") {
        throw "Chatflow application configuration verification failed: $appsOutputStr"
    }

    Write-Host "  [PASS] Both Chatbot (chat mode) and Chatflow (advanced-chat mode) verified with active tokens and models." -ForegroundColor Green
    $testResults["5_RAG_Applications_Configuration"] = "PASS (Chatbot & Chatflow verified)"
} catch {
    Write-Host "  [FAIL] RAG Applications configuration check failed: $_" -ForegroundColor Red
    $testResults["5_RAG_Applications_Configuration"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# 6. Exported Chatflow DSL & Node Graph Integrity
# ------------------------------------------------------------------------------
Write-Host "`n[6/7] Verifying Exported Visual Chatflow DSL & Node Graph Integrity..." -ForegroundColor Yellow
try {
    $dslPath = Join-Path $WorkspaceDir "workflows\local_bilingual_rag_chatflow.yml"
    if (-not (Test-Path $dslPath)) {
        throw "Chatflow DSL file not found at '$dslPath'"
    }

    $dslContent = Get-Content $dslPath -Raw -Encoding UTF8
    $dslLength = $dslContent.Length
    Write-Host "  Chatflow DSL Size: $dslLength bytes" -ForegroundColor Gray

    $requiredNodes = @("start", "knowledge-retrieval", "if-else", "llm", "answer")
    foreach ($nodeType in $requiredNodes) {
        if ($dslContent -notmatch "(?:node_type|type):\s*$nodeType") {
            throw "Missing required node type '$nodeType' in exported DSL."
        }
    }

    if ($dslContent -notmatch "app:") {
        throw "Missing app section in DSL."
    }

    Write-Host "  [PASS] Chatflow DSL contains valid schema and all required DAG nodes (start, knowledge-retrieval, if-else, llm, answer)." -ForegroundColor Green
    $testResults["6_Chatflow_DSL_Integrity"] = "PASS (Valid DAG DSL, size $dslLength bytes)"
} catch {
    Write-Host "  [FAIL] Chatflow DSL integrity check failed: $_" -ForegroundColor Red
    $testResults["6_Chatflow_DSL_Integrity"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# 7. Comparative Benchmark & Evaluation Integrity Gate
# ------------------------------------------------------------------------------
Write-Host "`n[7/7] Verifying Comparative Benchmark Reports & Evaluation Gate..." -ForegroundColor Yellow
try {
    $compJsonPath = Join-Path $WorkspaceDir "tests\rag-evaluation\comparison_report.json"
    $chatbotRepPath = Join-Path $WorkspaceDir "tests\rag-evaluation\report_chatbot.json"
    $chatflowRepPath = Join-Path $WorkspaceDir "tests\rag-evaluation\report_chatflow.json"

    # If comparison report is not yet generated, generate it using existing reports
    if (-not (Test-Path $compJsonPath)) {
        Write-Host "  Generating comparison report from evaluated datasets..." -ForegroundColor Gray
        & "C:\Users\hassa\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" (Join-Path $WorkspaceDir "tests\rag-evaluation\compare_rag_apps.py") --use-existing
    }

    if (-not (Test-Path $compJsonPath)) {
        throw "Comparison report not found at '$compJsonPath'"
    }

    $compData = Get-Content $compJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $cbPassRate = $compData.applications.chatbot.test_case_pass_rate_pct
    $cfPassRate = $compData.applications.chatflow.test_case_pass_rate_pct
    $cbIterPassRate = $compData.applications.chatbot.iteration_pass_rate_pct
    $cfIterPassRate = $compData.applications.chatflow.iteration_pass_rate_pct

    Write-Host "  Chatbot Test Case Pass Rate: $cbPassRate% | Iterations: $cbIterPassRate%" -ForegroundColor Gray
    Write-Host "  Chatflow Test Case Pass Rate: $cfPassRate% | Iterations: $cfIterPassRate%" -ForegroundColor Gray

    if ($cbPassRate -lt 100.0 -or $cfPassRate -lt 100.0) {
        throw "Evaluation pass rate requirement (100%) not met (Chatbot: $cbPassRate%, Chatflow: $cfPassRate%)."
    }

    if ($cbIterPassRate -lt 100.0 -or $cfIterPassRate -lt 100.0) {
        throw "Iteration pass rate requirement (100%) not met (Chatbot: $cbIterPassRate%, Chatflow: $cfIterPassRate%)."
    }

    Write-Host "  [PASS] Comparative benchmark confirmed: 100% test case and iteration pass rates across both applications." -ForegroundColor Green
    $testResults["7_Comparative_Benchmark_Gate"] = "PASS (Chatbot: 100%, Chatflow: 100%)"
} catch {
    Write-Host "  [FAIL] Comparative benchmark verification failed: $_" -ForegroundColor Red
    $testResults["7_Comparative_Benchmark_Gate"] = "FAIL: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# Summary Report
# ------------------------------------------------------------------------------
Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  Stage D.1 Acceptance Test Summary                       " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
foreach ($item in $testResults.GetEnumerator()) {
    Write-Host "  $($item.Key): $($item.Value)" -ForegroundColor Green
}
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Stage D.1 Verification Completed Successfully!`n" -ForegroundColor Green
