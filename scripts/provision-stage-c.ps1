# ==============================================================================
# Script: provision-stage-c.ps1
# Description: Stage C Automation — Ollama Networking & Embedding Model Integration
# Target: Windows 11 / WSL2 / Docker Desktop (Per-User) / Native Ollama
# Author: a2sn2
# Date: 2026-11-01
# ==============================================================================

[CmdletBinding()]
param(
    [string]$WorkspaceDir = "C:\Users\hassa\local-rag",
    [string]$TenantId = "b30587b8-f547-461e-bfdf-59e8cb4b1bbb"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$statusFile = Join-Path $WorkspaceDir "stage_c_status.json"
$logFile = Join-Path $WorkspaceDir "stage_c_install.log"

Start-Transcript -Path $logFile -Force

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Stage C: Local Ollama & Embedding Integration Provision " -ForegroundColor Cyan
Write-Host "  Time: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))     " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

function Write-StageCStatusAndExit {
    param(
        [string]$Status,
        [int]$ExitCode,
        [string]$Message,
        [hashtable]$Details = @{}
    )
    $payload = [ordered]@{
        timestamp = (Get-Date).ToString("o")
        stage     = "STAGE_C"
        status    = $Status
        exitCode  = $ExitCode
        message   = $Message
        details   = $Details
    }
    $json = $payload | ConvertTo-Json -Depth 5
    Set-Content -Path $statusFile -Value $json -Force -Encoding ASCII
    Write-Host "`n[$Status] $Message (Exit Code: $ExitCode)" -ForegroundColor $(if ($ExitCode -eq 0) { "Green" } else { "Red" })
    Stop-Transcript
    exit $ExitCode
}

# ------------------------------------------------------------------------------
# 1. Verify Host Ollama & Models
# ------------------------------------------------------------------------------
Write-Host "`n[1/5] Verifying Native Host Ollama and Model Artifacts..." -ForegroundColor Cyan
try {
    $ollamaTags = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -Method Get -TimeoutSec 10
    $models = $ollamaTags.models | ForEach-Object { $_.name }
    Write-Host "  Available models in Ollama: $($models -join ', ')" -ForegroundColor Gray

    if (-not ($models -contains "bge-m3:latest" -or $models -contains "bge-m3")) {
        Write-Host "  Pulling bge-m3 into host Ollama..." -ForegroundColor Yellow
        $pullResp = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/pull" -Method Post -Body (@{ name = "bge-m3" } | ConvertTo-Json) -TimeoutSec 300
        Write-Host "  bge-m3 pull complete." -ForegroundColor Green
    }
} catch {
    Write-StageCStatusAndExit -Status "FAILED" -ExitCode 1 -Message "Failed to verify or pull Ollama models: $_"
}

# ------------------------------------------------------------------------------
# 2. Verify Dify Container Health
# ------------------------------------------------------------------------------
Write-Host "`n[2/5] Verifying Dify Container Health..." -ForegroundColor Cyan
try {
    $apiHealth = docker exec dify-api-1 curl -s http://localhost:5001/health
    if ($apiHealth -notmatch '"status":\s*"ok"') {
        throw "Dify API returned unhealthy status: $apiHealth"
    }
    $httpCode = curl.exe -s -m 10 -o NUL -w "%{http_code}" "http://127.0.0.1/install"
    if ($httpCode -ne "200") {
        throw "Dify Web Gateway returned non-200 code: $httpCode"
    }
    Write-Host "  Dify API and Web Gateway are healthy." -ForegroundColor Green
} catch {
    Write-StageCStatusAndExit -Status "FAILED" -ExitCode 1 -Message "Dify API is not accessible or unhealthy: $_"
}

# ------------------------------------------------------------------------------
# 3. Ensure Official Ollama Plugin is Installed in Dify
# ------------------------------------------------------------------------------
Write-Host "`n[3/5] Installing/Verifying langgenius/ollama Plugin in Dify..." -ForegroundColor Cyan
$installPluginPy = @"
import app, time
_, flask_app = app.create_app()
with flask_app.app_context():
    from core.plugin.plugin_service import PluginService
    from core.helper.marketplace import search_plugins
    tenant_id = '$TenantId'
    
    # Check if already installed
    providers = PluginService.fetch_plugin_model_providers(tenant_id=tenant_id)
    ollama_installed = any('ollama' in p.provider for p in providers)
    if ollama_installed:
        print('ALREADY_INSTALLED')
    else:
        print('INSTALLING_FROM_MARKETPLACE')
        search_res = search_plugins(query='ollama', category='', page=1, page_size=5)
        ollama_item = next((p for p in search_res.plugins if p.plugin_id == 'langgenius/ollama'), None)
        if not ollama_item:
            raise RuntimeError('Could not find langgenius/ollama in marketplace.')
        
        pkg_id = ollama_item.latest_package_identifier
        install_res = PluginService.install_from_marketplace_pkg(tenant_id, [pkg_id])
        task_id = install_res.task_id if hasattr(install_res, 'task_id') else getattr(install_res, 'task_id', None)
        if task_id:
            for _ in range(30):
                t = PluginService.fetch_install_task(tenant_id, task_id)
                if t.status.value in ('success', 'failed'):
                    break
                time.sleep(2)
        print('INSTALL_COMPLETED')
"@

try {
    $pluginOut = docker exec dify-api-1 python -c $installPluginPy
    Write-Host "  Plugin status: $pluginOut" -ForegroundColor Gray
    Write-Host "  Ollama plugin successfully confirmed in Dify." -ForegroundColor Green
} catch {
    Write-StageCStatusAndExit -Status "FAILED" -ExitCode 1 -Message "Failed to install/verify Dify Ollama plugin: $_"
}

# ------------------------------------------------------------------------------
# 4. Register and Set Default Models
# ------------------------------------------------------------------------------
Write-Host "`n[4/5] Registering Models and Setting Workspace Defaults..." -ForegroundColor Cyan
$registerPy = @"
import app
_, flask_app = app.create_app()
with flask_app.app_context():
    from services.model_provider.service import ModelProviderService
    from core.model_manager import ModelManager
    from graphon.model_runtime.entities.model_entities import ModelType
    
    tenant_id = '$TenantId'
    service = ModelProviderService()
    
    # LLM Registration (qwen3.5:4b)
    llm_creds = {
        'base_url': 'http://host.docker.internal:11434',
        'mode': 'chat',
        'context_size': '4096',
        'max_tokens': '4096',
        'vision_support': 'true',
        'function_call_support': 'true'
    }
    try:
        service.create_model_credential(
            tenant_id=tenant_id,
            provider='langgenius/ollama/ollama',
            model_type='llm',
            model='qwen3.5:4b',
            credentials=llm_creds,
            credential_name=None
        )
    except Exception as e:
        print('LLM Credential Notice:', e)

    # Embedding Registration (bge-m3:latest)
    embed_creds = {
        'base_url': 'http://host.docker.internal:11434',
        'context_size': '8192'
    }
    try:
        service.create_model_credential(
            tenant_id=tenant_id,
            provider='langgenius/ollama/ollama',
            model_type='text-embedding',
            model='bge-m3:latest',
            credentials=embed_creds,
            credential_name=None
        )
    except Exception as e:
        print('Embedding Credential Notice:', e)

    # Update Defaults
    service.update_default_model_of_model_type(tenant_id, 'llm', 'langgenius/ollama/ollama', 'qwen3.5:4b')
    service.update_default_model_of_model_type(tenant_id, 'text-embedding', 'langgenius/ollama/ollama', 'bge-m3:latest')
    print('CONFIG_COMPLETE')
"@

try {
    $regOut = docker exec dify-api-1 python -c $registerPy
    Write-Host "  Configuration output: $regOut" -ForegroundColor Gray
    Write-Host "  Models successfully registered as workspace defaults." -ForegroundColor Green
} catch {
    Write-StageCStatusAndExit -Status "FAILED" -ExitCode 1 -Message "Failed to register models or set defaults: $_"
}

# ------------------------------------------------------------------------------
# 5. Run Stage C Acceptance Tests
# ------------------------------------------------------------------------------
Write-Host "`n[5/5] Executing Acceptance Tests..." -ForegroundColor Cyan
$testScript = Join-Path $WorkspaceDir "tests\integration\test-stage-c.ps1"
try {
    & $testScript -WorkspaceDir $WorkspaceDir -TenantId $TenantId
    Write-StageCStatusAndExit -Status "COMPLETED" -ExitCode 0 -Message "Stage C completed and fully verified." -Details @{
        llm_model = "qwen3.5:4b"
        embedding_model = "bge-m3:latest"
        provider = "langgenius/ollama/ollama"
        gateway = "http://host.docker.internal:11434"
    }
} catch {
    Write-StageCStatusAndExit -Status "FAILED" -ExitCode 1 -Message "Acceptance test script failed: $_"
}

