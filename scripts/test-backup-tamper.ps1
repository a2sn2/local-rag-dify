# ==============================================================================
# Script: test-backup-tamper.ps1
# Description: Stage E.1 Authenticated Encryption (AES-256-GCM) Tamper Detection Suite
# Protocol: Validates that ANY alteration or unauthorized access is cryptographically detected
# Author: a2sn2
# Date: 2026-11-01
# ==============================================================================

[CmdletBinding()]
param(
    [string]$WorkspaceDir = "C:\Users\hassa\local-rag",
    [string]$Passphrase = ""
)

$ErrorActionPreference = "Stop"

$pythonExe = "C:\Users\hassa\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
$cryptoScript = Join-Path $WorkspaceDir "scripts\backup_crypto.py"
$tempDir = Join-Path $WorkspaceDir "backups\tamper_test_sandbox"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Stage E.1: Authenticated Encryption Tamper Detection    " -ForegroundColor Cyan
Write-Host "  Algorithm: AES-256-GCM (128-bit Auth Tag, PBKDF2 100k)  " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Resolve key
if ([string]::IsNullOrWhiteSpace($Passphrase)) {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_RAG_BACKUP_KEY)) {
        $Passphrase = $env:LOCAL_RAG_BACKUP_KEY
    } else {
        $defaultKeyFile = Join-Path $WorkspaceDir ".secrets\backup.key"
        if (Test-Path $defaultKeyFile) {
            $Passphrase = (Get-Content $defaultKeyFile -Raw).Trim()
        }
    }
}

if ([string]::IsNullOrWhiteSpace($Passphrase)) {
    $Passphrase = "Ephemeral-TamperTest-Key-" + (Get-Random -Minimum 100000 -Maximum 999999)
}

if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force }
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

$results = [ordered]@{
    "timestamp" = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    "algorithm" = "AES-256-GCM"
    "auth_tag_length_bits" = 128
    "kdf" = "PBKDF2-HMAC-SHA256"
    "iterations" = 100000
    "test_cases" = [ordered]@{}
    "overall_tamper_gate" = "FAILED"
}

try {
    # Prepare dummy data
    $origFile = Join-Path $tempDir "original_payload.bin"
    $encFile = Join-Path $tempDir "archive.enc"
    $decFile = Join-Path $tempDir "decrypted_payload.bin"

    $dummyContent = "CONFIDENTIAL_RAG_DATABASE_DUMP_VERIFICATION_TEST_" + ("A" * 4096)
    [System.IO.File]::WriteAllText($origFile, $dummyContent, [System.Text.Encoding]::UTF8)

    # 1. Test Encrypt
    Write-Host "`n[1/5] Testing Authenticated Encryption (AES-256-GCM)..." -ForegroundColor Yellow
    $encOutput = & $pythonExe $cryptoScript encrypt --input $origFile --output $encFile --passphrase $Passphrase 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $encFile)) {
        throw "Encryption failed: $encOutput"
    }
    Write-Host "  [OK] Encrypted successfully: $((Get-Item $encFile).Length) bytes." -ForegroundColor Green

    # 2. Test Legitimate Decrypt
    Write-Host "`n[2/5] Testing Legitimate Decryption with Matching Key..." -ForegroundColor Yellow
    $decOutput = & $pythonExe $cryptoScript decrypt --input $encFile --output $decFile --passphrase $Passphrase 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Legitimate decryption failed: $decOutput"
    }
    $recovered = [System.IO.File]::ReadAllText($decFile, [System.Text.Encoding]::UTF8)
    if ($recovered -ne $dummyContent) {
        throw "Decrypted content does not match original payload!"
    }
    Write-Host "  [OK] Roundtrip payload matched 100% with valid GCM tag verification." -ForegroundColor Green
    $results["test_cases"]["TC_01_Legitimate_Decryption"] = "PASS"

    # 3. Test Wrong Key Attack
    Write-Host "`n[3/5] Testing Decryption with Wrong Key (Rejection Test)..." -ForegroundColor Yellow
    $wrongDecFile = Join-Path $tempDir "wrong_dec.bin"
    $wrongKey = "CompletelyWrongSecretKey12345!"
    
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $wrongOutput = & cmd.exe /c "`"$pythonExe`" `"$cryptoScript`" decrypt --input `"$encFile`" --output `"$wrongDecFile`" --passphrase `"$wrongKey`" 2>&1"
    $wrongExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEap

    if ($wrongExit -eq 3) {
        Write-Host "  [OK] Attack defeated: Wrong passphrase strictly rejected via GCM tag (Exit code 3)." -ForegroundColor Green
        $results["test_cases"]["TC_02_Wrong_Key_Rejected"] = "PASS"
    } else {
        throw "Security failure: Wrong key was not rejected with expected InvalidTag code (Exit: $wrongExit, Out: $wrongOutput)"
    }

    # 4. Test Single-Byte Ciphertext Tampering Attack
    Write-Host "`n[4/5] Testing 1-Byte Ciphertext Tampering Attack (Integrity Test)..." -ForegroundColor Yellow
    $tamperedFile = Join-Path $tempDir "tampered_ciphertext.enc"
    $encBytes = [System.IO.File]::ReadAllBytes($encFile)
    
    # Flip a single byte in the middle of ciphertext payload
    $flipOffset = [int]($encBytes.Length / 2)
    $encBytes[$flipOffset] = [byte]($encBytes[$flipOffset] -bxor 0xFF)
    [System.IO.File]::WriteAllBytes($tamperedFile, $encBytes)

    $tamperDecFile = Join-Path $tempDir "tamper_dec.bin"
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $tamperOutput = & cmd.exe /c "`"$pythonExe`" `"$cryptoScript`" decrypt --input `"$tamperedFile`" --output `"$tamperDecFile`" --passphrase `"$Passphrase`" 2>&1"
    $tamperExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEap

    if ($tamperExit -eq 3) {
        Write-Host "  [OK] Attack defeated: 1-byte alteration detected! GCM authentication tag rejected modified ciphertext." -ForegroundColor Green
        $results["test_cases"]["TC_03_Ciphertext_Tamper_Detected"] = "PASS"
    } else {
        throw "Security failure: Tampered ciphertext was not rejected with InvalidTag! (Exit: $tamperExit, Out: $tamperOutput)"
    }

    # 5. Test Header / Nonce Tampering Attack
    Write-Host "`n[5/5] Testing Nonce / Header Tampering Attack..." -ForegroundColor Yellow
    $tamperedHeaderFile = Join-Path $tempDir "tampered_header.enc"
    $headerBytes = [System.IO.File]::ReadAllBytes($encFile)
    # Flip a byte in the GCM nonce (offset 40: after 7 bytes magic + 32 bytes salt)
    $headerBytes[40] = [byte]($headerBytes[40] -bxor 0x01)
    [System.IO.File]::WriteAllBytes($tamperedHeaderFile, $headerBytes)

    $headerDecFile = Join-Path $tempDir "header_dec.bin"
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $headerOutput = & cmd.exe /c "`"$pythonExe`" `"$cryptoScript`" decrypt --input `"$tamperedHeaderFile`" --output `"$headerDecFile`" --passphrase `"$Passphrase`" 2>&1"
    $headerExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEap

    if ($headerExit -eq 3) {
        Write-Host "  [OK] Attack defeated: Nonce alteration detected! GCM authentication tag rejected tampered header." -ForegroundColor Green
        $results["test_cases"]["TC_04_Header_Tamper_Detected"] = "PASS"
    } else {
        throw "Security failure: Tampered header was not rejected! (Exit: $headerExit, Out: $headerOutput)"
    }

    $results["overall_tamper_gate"] = "PASSED"
    Write-Host "`n==========================================================" -ForegroundColor Cyan
    Write-Host "  All Cryptographic Tamper Detection Tests: PASSED!       " -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Cyan

} catch {
    Write-Host "`n[FAIL] Tamper Detection Test Failed: $_" -ForegroundColor Red
    $results["overall_tamper_gate"] = "FAILED"
    $results["error"] = $_.ToString()
} finally {
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force | Out-Null
    }
    $reportPath = Join-Path $WorkspaceDir "tests\rag-evaluation\tamper_detection_report.json"
    $results | ConvertTo-Json -Depth 5 | Out-File -FilePath $reportPath -Encoding utf8
    Write-Host "  Tamper report saved: $reportPath" -ForegroundColor Gray
}

if ($results["overall_tamper_gate"] -ne "PASSED") {
    exit 1
}
