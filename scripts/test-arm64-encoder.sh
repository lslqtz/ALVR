#!/bin/bash
# ALVR ARM64 Encoder Test Script
# 使用 Parallels Desktop 在 Windows on ARM VM 中测试 ARM64 编码器

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VM_NAME="Windows 11"
SHARED_DIR="/Users/Bowen/Parallels/Windows 11.pvm"
TEST_DIR="C:\\Users\\Public\\alvr-test"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 显示帮助
show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --quick     快速测试（仅验证启动）"
    echo "  --full      完整测试（包含编码功能）"
    echo "  --download  从 GitHub Actions 下载最新构建"
    echo "  --local     使用本地构建产物"
    echo "  -h, --help  显示帮助"
    echo ""
}

# 检查 VM 状态并启动
ensure_vm_running() {
    log_info "检查 VM 状态..."
    
    local status=$(prlctl list -o status "$VM_NAME" | tail -1)
    
    if [[ "$status" == "running" ]]; then
        log_info "VM 已在运行"
        return 0
    fi
    
    log_info "启动 VM: $VM_NAME"
    prlctl start "$VM_NAME"
    
    # 等待 VM 完全启动
    log_info "等待 VM 启动..."
    for i in {1..60}; do
        if prlctl exec "$VM_NAME" cmd /c "echo ready" 2>/dev/null | grep -q "ready"; then
            log_info "VM 已就绪"
            return 0
        fi
        sleep 2
    done
    
    log_error "VM 启动超时"
    return 1
}

# 从 GitHub Actions 下载 artifact
download_artifact() {
    log_info "从 GitHub Actions 下载最新构建..."
    
    local artifact_dir="$PROJECT_ROOT/target/arm64-artifact"
    mkdir -p "$artifact_dir"
    
    # 获取最新成功的 run
    local run_id=$(gh run list --workflow="arm64-encoder.yml" --status=success --limit=1 --json databaseId -q '.[0].databaseId')
    
    if [[ -z "$run_id" ]]; then
        log_error "没有找到成功的构建"
        return 1
    fi
    
    log_info "下载 Run ID: $run_id"
    gh run download "$run_id" -n "alvr-encoder-arm64" -D "$artifact_dir"
    
    log_info "下载完成: $artifact_dir"
    echo "$artifact_dir"
}

# 复制文件到 VM
copy_to_vm() {
    local source_dir="$1"
    
    log_info "创建 VM 测试目录..."
    prlctl exec "$VM_NAME" cmd /c "if not exist $TEST_DIR mkdir $TEST_DIR"
    
    log_info "复制文件到 VM..."
    
    # 使用共享目录复制（如果启用）或直接用 prlctl
    for file in "$source_dir"/*; do
        if [[ -f "$file" ]]; then
            local filename=$(basename "$file")
            log_info "  复制: $filename"
            # 使用 PowerShell 的 Copy-Item 通过 UNC 路径
            cat "$file" | prlctl exec "$VM_NAME" powershell -Command "\$input | Set-Content -Path '$TEST_DIR\\$filename' -Encoding Byte"
        fi
    done
    
    log_info "文件复制完成"
}

# 运行测试
run_tests() {
    local test_type="$1"
    
    log_info "运行 $test_type 测试..."
    
    # 复制测试脚本
    cat "$SCRIPT_DIR/test-encoder.ps1" | prlctl exec "$VM_NAME" powershell -Command "\$input | Set-Content -Path '$TEST_DIR\\test-encoder.ps1' -Encoding UTF8"
    
    # 执行测试
    local result
    if [[ "$test_type" == "quick" ]]; then
        result=$(prlctl exec "$VM_NAME" powershell -ExecutionPolicy Bypass -File "$TEST_DIR\\test-encoder.ps1" -Quick 2>&1)
    else
        result=$(prlctl exec "$VM_NAME" powershell -ExecutionPolicy Bypass -File "$TEST_DIR\\test-encoder.ps1" 2>&1)
    fi
    
    echo "$result"
    
    if echo "$result" | grep -q "ALL TESTS PASSED"; then
        log_info "✅ 测试通过！"
        return 0
    else
        log_error "❌ 测试失败"
        return 1
    fi
}

# 主函数
main() {
    local test_type="quick"
    local source="download"
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --quick)
                test_type="quick"
                shift
                ;;
            --full)
                test_type="full"
                shift
                ;;
            --download)
                source="download"
                shift
                ;;
            --local)
                source="local"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    log_info "=== ALVR ARM64 编码器测试 ==="
    log_info "测试类型: $test_type"
    log_info "文件来源: $source"
    echo ""
    
    # 确保 VM 运行
    ensure_vm_running
    
    # 获取构建产物
    local artifact_dir
    if [[ "$source" == "download" ]]; then
        artifact_dir=$(download_artifact)
    else
        artifact_dir="$PROJECT_ROOT/target/aarch64-pc-windows-msvc/release"
        if [[ ! -f "$artifact_dir/alvr_encoder_arm64.exe" ]]; then
            log_error "本地构建产物不存在: $artifact_dir/alvr_encoder_arm64.exe"
            exit 1
        fi
    fi
    
    # 复制到 VM
    copy_to_vm "$artifact_dir"
    
    # 运行测试
    run_tests "$test_type"
}

main "$@"
