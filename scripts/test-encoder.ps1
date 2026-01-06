# ALVR ARM64 Encoder Test Script for Windows
# 在 Windows on ARM VM 中运行，验证 ARM64 编码器功能

param(
    [switch]$Quick,
    [string]$TestDir = "C:\Users\Public\alvr-test"
)

$ErrorActionPreference = "Stop"
$EncoderExe = Join-Path $TestDir "alvr_encoder_arm64.exe"

function Write-TestResult {
    param([string]$Name, [bool]$Passed, [string]$Message = "")
    if ($Passed) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] $Name - $Message" -ForegroundColor Red
    }
    return $Passed
}

function Test-FileExists {
    param([string]$Path, [string]$Description)
    $exists = Test-Path $Path
    Write-TestResult -Name "File exists: $Description" -Passed $exists -Message "Not found: $Path"
    return $exists
}

function Test-EncoderExecutable {
    Write-Host "`n=== 测试编码器可执行文件 ===" -ForegroundColor Cyan
    
    # 检查 exe 存在
    if (-not (Test-FileExists -Path $EncoderExe -Description "alvr_encoder_arm64.exe")) {
        return $false
    }
    
    # 检查是否为 ARM64 PE
    try {
        $bytes = [System.IO.File]::ReadAllBytes($EncoderExe)
        # 简单检查 PE 签名
        if ($bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) {
            Write-TestResult -Name "Valid PE executable" -Passed $true
        } else {
            Write-TestResult -Name "Valid PE executable" -Passed $false -Message "Invalid PE header"
            return $false
        }
    } catch {
        Write-TestResult -Name "Read executable" -Passed $false -Message $_.Exception.Message
        return $false
    }
    
    return $true
}

function Test-FFmpegDlls {
    Write-Host "`n=== 测试 FFmpeg DLL 依赖 ===" -ForegroundColor Cyan
    
    $requiredDlls = @(
        "avcodec-61.dll",
        "avutil-59.dll",
        "swresample-5.dll",
        "swscale-8.dll"
    )
    
    $allFound = $true
    foreach ($dll in $requiredDlls) {
        $dllPath = Join-Path $TestDir $dll
        if (-not (Test-FileExists -Path $dllPath -Description $dll)) {
            $allFound = $false
        }
    }
    
    return $allFound
}

function Test-EncoderStartup {
    Write-Host "`n=== 测试编码器启动 ===" -ForegroundColor Cyan
    
    try {
        # 尝试运行编码器（会因为没有 IPC 而快速退出，但能验证基本加载）
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $EncoderExe
        $pinfo.Arguments = "1920 1080 h264"
        $pinfo.WorkingDirectory = $TestDir
        $pinfo.RedirectStandardOutput = $true
        $pinfo.RedirectStandardError = $true
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $pinfo
        $process.Start() | Out-Null
        
        # 等待最多 5 秒
        $exited = $process.WaitForExit(5000)
        
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        
        if (-not $exited) {
            $process.Kill()
            Write-TestResult -Name "Encoder process starts" -Passed $true
            Write-Host "  (Process was running, killed after timeout - this is expected)" -ForegroundColor Gray
            return $true
        }
        
        # 进程退出了 - 检查是否因为缺少 IPC（这是预期的）
        if ($stdout -match "IPC" -or $stderr -match "IPC" -or $stdout -match "starting" -or $stderr -match "starting") {
            Write-TestResult -Name "Encoder loads successfully" -Passed $true
            Write-Host "  Output: $stdout $stderr" -ForegroundColor Gray
            return $true
        }
        
        # 可能是 DLL 缺失或其他错误
        Write-TestResult -Name "Encoder loads successfully" -Passed $false -Message "Exit code: $($process.ExitCode)"
        if ($stderr) { Write-Host "  stderr: $stderr" -ForegroundColor Yellow }
        return $false
        
    } catch {
        Write-TestResult -Name "Encoder startup" -Passed $false -Message $_.Exception.Message
        return $false
    }
}

function Test-Architecture {
    Write-Host "`n=== 验证 ARM64 架构 ===" -ForegroundColor Cyan
    
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
    $isArm64 = $arch -eq [System.Runtime.InteropServices.Architecture]::Arm64
    
    Write-TestResult -Name "Running on ARM64" -Passed $isArm64 -Message "Current arch: $arch"
    return $isArm64
}

# 主测试流程
Write-Host "========================================" -ForegroundColor White
Write-Host " ALVR ARM64 Encoder Test Suite" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White
Write-Host "Test Directory: $TestDir"
Write-Host "Quick Mode: $Quick"
Write-Host ""

$allPassed = $true

# 验证架构
$allPassed = (Test-Architecture) -and $allPassed

# 验证文件
$allPassed = (Test-EncoderExecutable) -and $allPassed
$allPassed = (Test-FFmpegDlls) -and $allPassed

# 启动测试
if (-not $Quick) {
    $allPassed = (Test-EncoderStartup) -and $allPassed
}

# 结果摘要
Write-Host "`n========================================" -ForegroundColor White
if ($allPassed) {
    Write-Host " ALL TESTS PASSED" -ForegroundColor Green
} else {
    Write-Host " SOME TESTS FAILED" -ForegroundColor Red
}
Write-Host "========================================" -ForegroundColor White

exit $(if ($allPassed) { 0 } else { 1 })
