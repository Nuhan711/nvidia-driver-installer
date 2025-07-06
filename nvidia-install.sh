#!/bin/bash

# NVIDIA 驱动多系统通用安装脚本

# Author: PEScn @ EM-GeekLab
# Modified: 2025-07-02
# License: MIT
# GitHub: https://github.com/EM-GeekLab/nvidia-driver-installer
# Website: https://nvidia-install.online
# 基于 NVIDIA Driver Installation Guide: https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/index.html
# 支持 RHEL系、SUSE系、Debian系、Fedora、Amazon Linux、Azure Linux等发行版

set -e

# Color Definitions for echo output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m' # No Color

# Exit code definitions for automation
readonly EXIT_SUCCESS=0

# 权限和环境错误 (1-9)
readonly EXIT_NO_ROOT=1
readonly EXIT_PERMISSION_DENIED=2
readonly EXIT_STATE_DIR_FAILED=3

# 硬件检测错误 (10-19) 
readonly EXIT_NO_NVIDIA_GPU=10
readonly EXIT_LSPCI_UNAVAILABLE=11
readonly EXIT_GPU_ARCH_INCOMPATIBLE=12

# 系统兼容性错误 (20-29)
readonly EXIT_UNSUPPORTED_OS=20
readonly EXIT_UNSUPPORTED_VERSION=21
readonly EXIT_UNSUPPORTED_ARCH=22

# 参数和配置错误 (30-39)
readonly EXIT_INVALID_ARGS=30
readonly EXIT_INVALID_INSTALL_TYPE=31
readonly EXIT_MODULE_ARCH_MISMATCH=32

# Secure Boot相关错误 (40-49)
readonly EXIT_SECURE_BOOT_USER_EXIT=40
readonly EXIT_SECURE_BOOT_AUTO_FAILED=41
readonly EXIT_MOK_OPERATION_FAILED=42
readonly EXIT_MOK_TOOLS_MISSING=43

# 现有驱动冲突 (50-59)
readonly EXIT_EXISTING_DRIVER_USER_EXIT=50
readonly EXIT_DRIVER_UNINSTALL_FAILED=51
readonly EXIT_NOUVEAU_DISABLE_FAILED=52

# 网络和下载错误 (60-69)
readonly EXIT_NETWORK_FAILED=60
readonly EXIT_REPO_DOWNLOAD_FAILED=61
readonly EXIT_KEYRING_DOWNLOAD_FAILED=62

# 包管理器错误 (70-79)
readonly EXIT_PACKAGE_MANAGER_UNAVAILABLE=70
readonly EXIT_REPO_ADD_FAILED=71
readonly EXIT_DEPENDENCY_INSTALL_FAILED=72
readonly EXIT_KERNEL_HEADERS_FAILED=73
readonly EXIT_NVIDIA_INSTALL_FAILED=74

# 系统状态错误 (80-89)
readonly EXIT_KERNEL_VERSION_ISSUE=80
readonly EXIT_DKMS_BUILD_FAILED=81
readonly EXIT_MODULE_SIGNING_FAILED=82
readonly EXIT_DRIVER_VERIFICATION_FAILED=83

# 状态管理错误 (90-99)
readonly EXIT_ROLLBACK_FILE_MISSING=90
readonly EXIT_ROLLBACK_FAILED=91
readonly EXIT_STATE_FILE_CORRUPTED=92

# 用户取消 (100-109)
readonly EXIT_USER_CANCELLED=100

# 全局变量
DISTRO_ID=""
DISTRO_VERSION=""
DISTRO_CODENAME=""
ARCH=""
USE_OPEN_MODULES=true
INSTALL_TYPE="full"  # full, compute-only, desktop-only
USE_LOCAL_REPO=false
FORCE_REINSTALL=false
SKIP_EXISTING_CHECKS=false
AUTO_YES=false
QUIET_MODE=false
REBOOT_AFTER_INSTALL=false
DRIVER_VERSION=""

# 状态跟踪文件
STATE_DIR="/var/lib/nvidia-installer"
STATE_FILE="$STATE_DIR/install.state"
ROLLBACK_FILE="$STATE_DIR/rollback.list"

# 环境变量配置支持
NVIDIA_INSTALLER_AUTO_YES=${NVIDIA_INSTALLER_AUTO_YES:-false}
NVIDIA_INSTALLER_QUIET=${NVIDIA_INSTALLER_QUIET:-false}
NVIDIA_INSTALLER_MODULES=${NVIDIA_INSTALLER_MODULES:-"open"}
NVIDIA_INSTALLER_TYPE=${NVIDIA_INSTALLER_TYPE:-"full"}
NVIDIA_INSTALLER_FORCE=${NVIDIA_INSTALLER_FORCE:-false}
NVIDIA_INSTALLER_REBOOT=${NVIDIA_INSTALLER_REBOOT:-false}

# 优雅退出处理
cleanup_on_exit() {
    local exit_code=$?
    local signal="${1:-EXIT}"
    
    log_debug "收到信号: $signal, 退出码: $exit_code"
    
    # 如果是被信号中断，记录中断信息
    if [[ "$signal" != "EXIT" ]]; then
        log_warning "脚本被信号 $signal 中断"
        
        # 保存中断状态
        if [[ -d "$STATE_DIR" ]]; then
            echo "INTERRUPTED=true" >> "$STATE_DIR/last_exit_code"
            echo "SIGNAL=$signal" >> "$STATE_DIR/last_exit_code"
            echo "INTERRUPT_TIME=$(date '+%Y-%m-%d %H:%M:%S')" >> "$STATE_DIR/last_exit_code"
        fi
    fi
    
    # 清理临时文件
    cleanup_temp_files
    
    # 如果安装过程中被中断，保存当前状态
    if [[ "$signal" != "EXIT" ]] && [[ -f "$STATE_FILE" ]]; then
        log_info "保存中断状态，可使用相同命令继续安装"
    fi
    
    # 释放可能的锁文件
    cleanup_lock_files
    
    # 根据信号设置适当的退出码
    case "$signal" in
        "INT"|"TERM")
            exit 130  # 标准的信号中断退出码
            ;;
        "EXIT")
            exit $exit_code  # 保持原始退出码
            ;;
        *)
            exit 1
            ;;
    esac
}

# 清理临时文件
cleanup_temp_files() {
    log_debug "开始清理临时文件..."
    find /tmp -maxdepth 1 \( \
        -name "nvidia-driver-local-repo-*.rpm" -o \
        -name "nvidia-driver-local-repo-*.deb" -o \
        -name "cuda-keyring*.deb" -o \
        -name "nvidia-installer-*.log" \
    \) -print -delete
}

# 清理锁文件
cleanup_lock_files() {
    local lock_files=(
        "/tmp/.nvidia-installer.lock"
        "/var/lock/nvidia-installer.lock"
        "$STATE_DIR/.install.lock"
    )
    
    for lock_file in "${lock_files[@]}"; do
        if [[ -f "$lock_file" ]]; then
            log_debug "释放锁文件: $lock_file"
            rm -f "$lock_file"
        fi
    done
}

# 创建安装锁
create_install_lock() {
    local lock_file="$STATE_DIR/.install.lock"
    
    if [[ -f "$lock_file" ]]; then
        local lock_pid=$(cat "$lock_file" 2>/dev/null)
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            exit_with_code $EXIT_STATE_FILE_CORRUPTED "另一个安装进程正在运行 (PID: $lock_pid)"
        else
            log_warning "发现孤立的锁文件，将清理"
            rm -f "$lock_file"
        fi
    fi
    
    echo $$ > "$lock_file"
    log_debug "创建安装锁: $lock_file (PID: $$)"
}

# 设置信号处理
trap 'cleanup_on_exit INT' INT
trap 'cleanup_on_exit TERM' TERM  
trap 'cleanup_on_exit EXIT' EXIT

# 错误处理函数
exit_with_code() {
    local exit_code=$1
    local message="$2"
    
    log_error "$message"
    
    # 在调试模式下显示退出码
    if [[ "${DEBUG:-false}" == "true" ]]; then
        log_debug "退出码: $exit_code"
    fi
    
    # 保存退出码到状态文件供外部查询
    if [[ -d "$STATE_DIR" ]]; then
        echo "EXIT_CODE=$exit_code" > "$STATE_DIR/last_exit_code"
        echo "EXIT_MESSAGE=$message" >> "$STATE_DIR/last_exit_code"
        echo "EXIT_TIME=$(date '+%Y-%m-%d %H:%M:%S')" >> "$STATE_DIR/last_exit_code"
    fi
    
    exit $exit_code
}

# 获取退出码描述
get_exit_code_description() {
    local code=$1
    case $code in
        0) echo "成功完成" ;;
        1) echo "非root权限运行" ;;
        2) echo "文件系统权限不足" ;;
        3) echo "状态目录创建失败" ;;
        10) echo "未检测到NVIDIA GPU" ;;
        11) echo "lspci命令不可用" ;;
        12) echo "GPU架构不兼容" ;;
        20) echo "不支持的操作系统" ;;
        21) echo "不支持的发行版版本" ;;
        22) echo "不支持的系统架构" ;;
        30) echo "无效的命令行参数" ;;
        31) echo "无效的安装类型" ;;
        32) echo "模块类型与GPU架构不匹配" ;;
        40) echo "Secure Boot启用，用户选择退出" ;;
        41) echo "Secure Boot启用，自动化模式无法处理" ;;
        42) echo "MOK密钥操作失败" ;;
        43) echo "缺少MOK管理工具" ;;
        50) echo "现有驱动冲突，用户选择退出" ;;
        51) echo "现有驱动卸载失败" ;;
        52) echo "nouveau驱动禁用失败" ;;
        60) echo "网络连接失败" ;;
        61) echo "仓库下载失败" ;;
        62) echo "CUDA keyring下载失败" ;;
        70) echo "包管理器不可用" ;;
        71) echo "仓库添加失败" ;;
        72) echo "依赖包安装失败" ;;
        73) echo "内核头文件安装失败" ;;
        74) echo "NVIDIA驱动安装失败" ;;
        80) echo "内核版本问题" ;;
        81) echo "DKMS构建失败" ;;
        82) echo "模块签名失败" ;;
        83) echo "驱动验证失败" ;;
        90) echo "回滚文件缺失" ;;
        91) echo "回滚操作失败" ;;
        92) echo "状态文件损坏" ;;
        100) echo "用户取消安装" ;;
        *) echo "未知错误码: $code" ;;
    esac
}

# 日志函数
log_info() {
    if [[ "$QUIET_MODE" != "true" ]]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    fi
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_step() {
    if [[ "$QUIET_MODE" != "true" ]]; then
        echo -e "${PURPLE}[STEP]${NC} $1"
    fi
}

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]] && ! [[ "$QUIET_MODE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

# 交互式确认函数
confirm() {
    local prompt="$1"
    local default="${2:-N}"

    if [[ "$AUTO_YES" == "true" ]]; then
        log_debug "自动确认: $prompt -> Y"
        return 0
    fi
    
    if [[ "$default" == "Y" ]]; then
        read -p "$prompt (Y/n): " -r
        [[ ! $REPLY =~ ^[Nn]$ ]]
    else
        read -p "$prompt (y/N): " -r
        [[ $REPLY =~ ^[Yy]$ ]]
    fi
}

# 选择菜单函数 (支持自动化)
select_option() {
    local prompt="$1"
    local default="$2"
    shift 2
    local options=("$@")

    if [[ "$AUTO_YES" == "true" ]]; then
        log_debug "自动选择: $prompt -> $default"
        echo "$default"
        return 0
    fi
    
    echo "$prompt"
    for i in "${!options[@]}"; do
        echo "$((i+1)). ${options[$i]}"
    done
    echo
    
    while true; do
        read -p "请选择 (1-${#options[@]}, 默认: $default): " -r choice
        
        # 如果用户直接回车，使用默认值
        if [[ -z "$choice" ]]; then
            choice="$default"
        fi
        
        # 验证输入
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#options[@]} ]]; then
            echo "$choice"
            return 0
        else
            echo "无效选择，请输入 1-${#options[@]} 之间的数字"
        fi
    done
}

# 显示用法
show_usage() {
    cat << EOF
用法: $0 [选项]

基本选项:
    -h, --help              显示此帮助信息
    -t, --type TYPE         安装类型: full, compute-only, desktop-only (默认: full)
    -m, --modules TYPE      内核模块类型: open, proprietary (默认: open)
    -l, --local             使用本地仓库安装
    -v, --version VERSION   指定驱动版本 (例如: 575)

自动化选项:
    -y, --yes               自动确认所有提示 (无交互模式)
    -q, --quiet             静默模式，减少输出
    -f, --force             强制重新安装，即使已安装驱动
    -s, --skip-checks       跳过现有安装检查
    --auto-reboot           安装完成后自动重启

高级选项:
    --cleanup               清理失败的安装状态并退出
    --rollback              回滚到安装前状态
    --show-exit-codes       显示所有退出码及其含义

环境变量:
    NVIDIA_INSTALLER_AUTO_YES=true     等同于 -y
    NVIDIA_INSTALLER_QUIET=true        等同于 -q  
    NVIDIA_INSTALLER_MODULES=open      等同于 -m open
    NVIDIA_INSTALLER_TYPE=full         等同于 -t full
    NVIDIA_INSTALLER_FORCE=true        等同于 -f
    NVIDIA_INSTALLER_REBOOT=true       等同于 --auto-reboot

示例:
    # 交互式安装
    $0
    
    # 完全自动化安装
    $0 -y -q --auto-reboot
    
    # 无交互计算专用安装
    $0 -y -t compute-only -m proprietary
    
    # 环境变量方式
    NVIDIA_INSTALLER_AUTO_YES=true NVIDIA_INSTALLER_TYPE=compute-only $0
    
    # CI/CD环境使用
    $0 -y -q -f -t full --auto-reboot

注意: 
- 开源模块仅支持 Turing 及更新架构 GPU
- Maxwell、Pascal、Volta 架构必须使用专有模块
- 脚本支持幂等操作，可安全重复运行
- 自动化模式下会使用合理的默认值
EOF
}

# 显示退出码信息
show_exit_codes() {
    cat << 'EOF'
NVIDIA驱动安装脚本 - 退出码说明

═══════════════════════════════════════════════════════════════

退出码分类说明：
• 0      : 成功
• 1-9    : 权限和环境错误
• 10-19  : 硬件检测错误
• 20-29  : 系统兼容性错误
• 30-39  : 参数和配置错误
• 40-49  : Secure Boot相关错误
• 50-59  : 现有驱动冲突
• 60-69  : 网络和下载错误
• 70-79  : 包管理器错误
• 80-89  : 系统状态错误
• 90-99  : 状态管理错误
• 100-109: 用户取消

详细退出码列表：

权限和环境错误 (1-9):
  1  - 非root权限运行
  2  - 文件系统权限不足
  3  - 状态目录创建失败

硬件检测错误 (10-19):
  10 - 未检测到NVIDIA GPU
  11 - lspci命令不可用
  12 - GPU架构不兼容

系统兼容性错误 (20-29):
  20 - 不支持的操作系统
  21 - 不支持的发行版版本
  22 - 不支持的系统架构

参数和配置错误 (30-39):
  30 - 无效的命令行参数
  31 - 无效的安装类型
  32 - 模块类型与GPU架构不匹配

Secure Boot相关错误 (40-49):
  40 - Secure Boot启用，用户选择退出
  41 - Secure Boot启用，自动化模式无法处理
  42 - MOK密钥操作失败
  43 - 缺少MOK管理工具

现有驱动冲突 (50-59):
  50 - 现有驱动冲突，用户选择退出
  51 - 现有驱动卸载失败
  52 - nouveau驱动禁用失败

网络和下载错误 (60-69):
  60 - 网络连接失败
  61 - 仓库下载失败
  62 - CUDA keyring下载失败

包管理器错误 (70-79):
  70 - 包管理器不可用
  71 - 仓库添加失败
  72 - 依赖包安装失败
  73 - 内核头文件安装失败
  74 - NVIDIA驱动安装失败

系统状态错误 (80-89):
  80 - 内核版本问题
  81 - DKMS构建失败
  82 - 模块签名失败
  83 - 驱动验证失败

状态管理错误 (90-99):
  90 - 回滚文件缺失
  91 - 回滚操作失败
  92 - 状态文件损坏

用户取消 (100-109):
  100 - 用户取消安装

═══════════════════════════════════════════════════════════════

外部处理示例:

# Bash脚本处理
./install_nvidia.sh -y
case $? in
  0) echo "安装成功" ;;
  10) echo "无GPU，跳过" ;;
  40) echo "Secure Boot问题" ;;
  60-69) echo "网络问题，可重试" ;;
  *) echo "其他错误" ;;
esac

# 查看最后的退出码
cat /var/lib/nvidia-installer/last_exit_code

EOF
}

# 解析命令行参数
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -t|--type)
                INSTALL_TYPE="$2"
                shift 2
                ;;
            -m|--modules)
                if [[ "$2" == "proprietary" ]]; then
                    USE_OPEN_MODULES=false
                elif [[ "$2" == "open" ]]; then
                    USE_OPEN_MODULES=true
                else
                    exit_with_code $EXIT_INVALID_ARGS "无效的模块类型: $2 (应为 open 或 proprietary)"
                fi
                shift 2
                ;;
            -l|--local)
                USE_LOCAL_REPO=true
                shift
                ;;
            -v|--version)
                DRIVER_VERSION="$2"
                shift 2
                ;;
            -y|--yes)
                AUTO_YES=true
                shift
                ;;
            -q|--quiet)
                QUIET_MODE=true
                shift
                ;;
            -f|--force)
                FORCE_REINSTALL=true
                shift
                ;;
            -s|--skip-checks)
                SKIP_EXISTING_CHECKS=true
                shift
                ;;
            --auto-reboot)
                REBOOT_AFTER_INSTALL=true
                shift
                ;;
            --cleanup)
                cleanup_failed_install
                exit 0
                ;;
            --rollback)
                rollback_installation
                exit 0
                ;;
            --show-exit-codes)
                show_exit_codes
                exit 0
                ;;
            *)
                exit_with_code $EXIT_INVALID_ARGS "未知选项: $1"
                ;;
        esac
    done

    # 处理环境变量
    if [[ "$NVIDIA_INSTALLER_AUTO_YES" == "true" ]]; then
        AUTO_YES=true
    fi
    
    if [[ "$NVIDIA_INSTALLER_QUIET" == "true" ]]; then
        QUIET_MODE=true
    fi
    
    if [[ "$NVIDIA_INSTALLER_FORCE" == "true" ]]; then
        FORCE_REINSTALL=true
    fi
    
    if [[ "$NVIDIA_INSTALLER_REBOOT" == "true" ]]; then
        REBOOT_AFTER_INSTALL=true
    fi
    
    if [[ -n "$NVIDIA_INSTALLER_MODULES" ]]; then
        if [[ "$NVIDIA_INSTALLER_MODULES" == "proprietary" ]]; then
            USE_OPEN_MODULES=false
        elif [[ "$NVIDIA_INSTALLER_MODULES" == "open" ]]; then
            USE_OPEN_MODULES=true
        fi
    fi
    
    if [[ -n "$NVIDIA_INSTALLER_TYPE" ]]; then
        INSTALL_TYPE="$NVIDIA_INSTALLER_TYPE"
    fi

    # 验证安装类型
    if [[ ! "$INSTALL_TYPE" =~ ^(full|compute-only|desktop-only)$ ]]; then
        exit_with_code $EXIT_INVALID_INSTALL_TYPE "无效的安装类型: $INSTALL_TYPE"
    fi
    
    # 自动化模式下的合理默认值
    if [[ "$AUTO_YES" == "true" ]]; then
        log_debug "自动化模式已启用"
        if [[ "$QUIET_MODE" == "true" ]]; then
            log_debug "静默模式已启用"
        fi
    fi
}

# 状态管理函数
create_state_dir() {
    if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
        exit_with_code $EXIT_STATE_DIR_FAILED "无法创建状态目录: $STATE_DIR"
    fi
    chmod 755 "$STATE_DIR"
    
    # 创建安装锁，防止并发安装
    create_install_lock
}

save_state() {
    local step="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $step" >> "$STATE_FILE"
}

get_last_state() {
    if [[ -f "$STATE_FILE" ]]; then
        tail -1 "$STATE_FILE" | cut -d: -f2- | sed 's/^ *//'
    fi
}

is_step_completed() {
    local step="$1"
    if [[ -f "$STATE_FILE" ]]; then
        grep -q ": $step$" "$STATE_FILE"
    else
        return 1
    fi
}

save_rollback_info() {
    local action="$1"
    echo "$action" >> "$ROLLBACK_FILE"
}

# 清理失败的安装状态
cleanup_failed_install() {
    log_info "清理失败的安装状态..."
    
    if [[ -f "$STATE_FILE" ]]; then
        log_info "发现之前的安装状态："
        if [[ "$QUIET_MODE" != "true" ]]; then
            cat "$STATE_FILE"
        fi
        
        if confirm "是否清理这些状态文件？" "N"; then
            rm -f "$STATE_FILE" "$ROLLBACK_FILE"
            log_success "安装状态已清理"
        fi
    else
        log_info "未发现失败的安装状态"
    fi
}

# 回滚安装
rollback_installation() {
    log_info "开始回滚安装..."
    
    if [[ ! -f "$ROLLBACK_FILE" ]]; then
        exit_with_code $EXIT_ROLLBACK_FILE_MISSING "未找到回滚信息文件: $ROLLBACK_FILE"
    fi
    
    log_warning "这将撤销所有通过此脚本进行的更改"
    if confirm "是否继续回滚？" "N"; then
        # 从后往前执行回滚操作
        local rollback_failed=false
        tac "$ROLLBACK_FILE" | while read -r action; do
            log_info "执行回滚: $action"
            if ! eval "$action"; then
                log_warning "回滚操作失败: $action"
                rollback_failed=true
            fi
        done

        if [[ "$rollback_failed" == "true" ]]; then
            exit_with_code $EXIT_ROLLBACK_FAILED "部分回滚操作失败，系统可能处于不一致状态"
        fi
        
        # 清理状态文件
        rm -f "$STATE_FILE" "$ROLLBACK_FILE"
        log_success "回滚完成"
    else
        exit_with_code $EXIT_USER_CANCELLED "用户取消回滚操作"
    fi
}

# 检测操作系统发行版
detect_distro() {
    log_step "检测操作系统发行版..."
    
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        DISTRO_ID=$ID
        DISTRO_VERSION=$VERSION_ID
        DISTRO_CODENAME=${VERSION_CODENAME:-}
        
        # 确定架构
        ARCH=$(uname -m)
        if [[ "$ARCH" == "x86_64" ]]; then
            ARCH="x86_64"
        elif [[ "$ARCH" == "aarch64" ]]; then
            ARCH="sbsa"
        else
            exit_with_code $EXIT_UNSUPPORTED_ARCH "不支持的架构: $ARCH (仅支持 x86_64 和 aarch64)"
        fi
        
        log_success "检测到发行版: $NAME ($DISTRO_ID $DISTRO_VERSION) [$ARCH]"
    else
        exit_with_code $EXIT_UNSUPPORTED_OS "无法检测操作系统发行版"
    fi
}

# GPU架构检测数据库
# 数据主要来源于 The PCI ID Repository (http://pci-ids.ucw.cz/) 和 NVIDIA 官方文档。
declare -A GPU_ARCH_DB

# 初始化GPU架构数据库
init_gpu_database() {
    # Maxwell架构 (GM1xx, GM2xx) - 需要专有模块
    # GTX 900系列, GTX 700系列部分
    local maxwell_ids=(
        "1380" "1381" "1382" "1390" "1391" "1392" "1393" "1398" "1399"  # GM107
        "13c0" "13c2" "13d7" "13d8" "13d9" "13da" "13f0" "13f1" "13f2" "13f3"  # GM204
        "17c2" "17c8" "17f0" "17f1"  # GM200
        "1340" "1341" "1344" "1346" "1347" "1348" "1349" "134b" "134d" "134e" "134f"  # GM108
    )
    
    # Pascal架构 (GP1xx) - 需要专有模块
    # GTX 10系列, GTX 16系列部分
    local pascal_ids=(
        "15f7" "15f8" "15f9"  # GP100
        "1b00" "1b02" "1b06" "1b30" "1b80" "1b81" "1b82" "1b83" "1b84" "1b87"  # GP102
        "1be0" "1be1" "1c02" "1c03" "1c04" "1c06" "1c07" "1c09" "1c20" "1c21" "1c22" "1c23"  # GP104
        "1c30" "1c31" "1c35" "1c60" "1c61" "1c62" "1c81" "1c82" "1c8c" "1c8d" "1c8f"  # GP106
        "1c90" "1c91" "1c92" "1c94" "1c96" "1cb1" "1cb2" "1cb3" "1cb6" "1cba" "1cbb" "1cbc"  # GP107
        "1d01" "1d10" "1d11" "1d12" "1d13" "1d16" "1d81"  # GP108
    )
    
    # Volta架构 (GV1xx) - 需要专有模块 (主要是Tesla产品)
    local volta_ids=(
        "1db0" "1db1" "1db3" "1db4" "1db5" "1db6" "1db7" "1db8"  # GV100
        "1df0" "1df2" "1df5" "1df6"  # GV100变种
    )
    
    # Turing架构 (TU1xx) - 支持开源模块
    # RTX 20系列, GTX 16系列
    local turing_ids=(
        "1e02" "1e04" "1e07" "1e09" "1e30" "1e36" "1e78" "1e81" "1e82" "1e84" "1e87" "1e89" "1e90" "1e91"  # TU102
        "1f02" "1f03" "1f06" "1f07" "1f08" "1f09" "1f0a" "1f10" "1f11" "1f12" "1f14" "1f15" "1f36" "1f42" "1f47" "1f50" "1f51" "1f54" "1f55" "1f76" "1f82" "1f83" "1f95" "1f96" "1f97" "1f98" "1f99" "1f9c" "1f9d" "1f9f" "1fa0" "1fb0" "1fb1" "1fb2" "1fb6" "1fb7" "1fb8" "1fb9" "1fba" "1fbb" "1fbc" "1fdd"  # TU104/TU106
        "1ff0" "1ff2" "1ff9" "1ffa" "1ffb" "1ffc" "1ffd" "1fff"  # TU117
    )
    
    # Ampere架构 (GA1xx) - 支持开源模块
    # RTX 30系列, RTX A系列
    local ampere_ids=(
        "2204" "2205" "2206" "2207" "2208" "220a" "2216" "2230" "2231" "2232" "2233" "2235" "2236"  # GA102
        "2484" "2486" "2487" "2488" "2489" "248a" "249c" "249d" "24a0" "24b0" "24b1" "24b6" "24b7" "24b8" "24b9" "24ba" "24bb" "24c7" "24c9" "24dc" "24dd" "24e0" "24fa"  # GA104
        "2501" "2503" "2504" "2505" "2507" "2508" "2520" "2521" "2523" "2531" "2544" "2545" "2548" "254b" "2560" "2563" "2571" "2582" "2583" "2584"  # GA106
        "25a0" "25a2" "25a5" "25a6" "25a7" "25a9" "25aa" "25ab" "25ac" "25ad" "25b0" "25b6" "25b8" "25b9" "25ba" "25bb" "25bc" "25bd" "25e0" "25e2" "25e5" "25f9" "25fa" "25fb" "25fc"  # GA107
    )
    
    # Ada Lovelace架构 (AD1xx) - 支持开源模块
    # RTX 40系列
    local ada_ids=(
        "2684" "2685" "2688" "2689" "268a" "268b" "268e" "268f"  # AD102
        "2704" "2705" "2706" "2708" "2709" "270a" "270b" "270d" "270f" "2717" "2718" "2730" "2757" "2760"  # AD104
        "2803" "2805" "2820" "2838" "2860" "2882" "2887" "2888"  # AD106
        "28a0" "28a1" "28b0" "28b8" "28b9" "28ba" "28bb" "28bc" "28e0" "28e1"  # AD107
    )
    
    # Blackwell架构 (GB1xx) - 支持开源模块 (最新架构)
    local blackwell_ids=(
        "2330" "2331" "2335" "233a" "233d" "2342"  # GB202 (RTX 50系列预期)
        "2770" "2782"  # GB100 (数据中心)
    )
    
    # 填充数据库
    for id in "${maxwell_ids[@]}"; do
        GPU_ARCH_DB["$id"]="Maxwell"
    done
    
    for id in "${pascal_ids[@]}"; do
        GPU_ARCH_DB["$id"]="Pascal"
    done
    
    for id in "${volta_ids[@]}"; do
        GPU_ARCH_DB["$id"]="Volta"
    done
    
    for id in "${turing_ids[@]}"; do
        GPU_ARCH_DB["$id"]="Turing"
    done
    
    for id in "${ampere_ids[@]}"; do
        GPU_ARCH_DB["$id"]="Ampere"
    done
    
    for id in "${ada_ids[@]}"; do
        GPU_ARCH_DB["$id"]="Ada Lovelace"
    done
    
    for id in "${blackwell_ids[@]}"; do
        GPU_ARCH_DB["$id"]="Blackwell"
    done
}

# 检测GPU架构
detect_gpu_architecture() {
    local device_id="$1"
    local architecture="${GPU_ARCH_DB[$device_id]}"
    
    if [[ -n "$architecture" ]]; then
        echo "$architecture"
    else
        echo "Unknown"
    fi
}

# 检查架构是否支持开源模块
is_open_module_supported() {
    local architecture="$1"
    
    case "$architecture" in
        "Turing"|"Ampere"|"Ada Lovelace"|"Blackwell")
            return 0  # 支持开源模块
            ;;
        "Maxwell"|"Pascal"|"Volta")
            return 1  # 需要专有模块
            ;;
        *)
            return 1  # 未知架构，保守选择专有模块
            ;;
    esac
}

# 检查NVIDIA GPU并确定架构兼容性
check_nvidia_gpu() {
    log_step "检查NVIDIA GPU并确定架构兼容性..."
    
    if ! command -v lspci &> /dev/null; then
        exit_with_code $EXIT_LSPCI_UNAVAILABLE "lspci命令未找到，请安装pciutils包"
    fi
    
    if ! lspci | grep -i nvidia > /dev/null 2>&1; then
        exit_with_code $EXIT_NO_NVIDIA_GPU "未检测到NVIDIA GPU"
    fi
    
    # 初始化GPU数据库
    init_gpu_database
    
    # 获取所有NVIDIA GPU
    local gpu_count=0
    local has_incompatible_gpu=false
    local detected_architectures=()
    
    while IFS= read -r line; do
        ((gpu_count++))
        local gpu_info=$(echo "$line" | grep -E "(VGA|3D controller)")
        if [[ -n "$gpu_info" ]]; then
            log_success "检测到NVIDIA GPU #$gpu_count: $gpu_info"
            
            # 提取设备ID
            local pci_line=$(lspci -n | grep "$(echo "$line" | awk '{print $1}')")
            local device_id=$(echo "$pci_line" | awk -F'[: ]+' '/10de:/ {print $4}' | tr '[:lower:]' '[:upper:]')
            
            if [[ -n "$device_id" ]]; then
                local architecture=$(detect_gpu_architecture "$device_id")
                detected_architectures+=("$architecture")
                
                log_info "GPU #$gpu_count 设备ID: $device_id, 架构: $architecture"
                
                # 检查模块兼容性
                if [[ "$USE_OPEN_MODULES" == "true" ]]; then
                    if is_open_module_supported "$architecture"; then
                        log_success "GPU #$gpu_count ($architecture) 支持开源内核模块"
                    else
                        log_error "GPU #$gpu_count ($architecture) 不支持开源内核模块"
                        has_incompatible_gpu=true
                    fi
                else
                    log_info "GPU #$gpu_count ($architecture) 将使用专有内核模块"
                fi
            else
                log_warning "无法确定GPU #$gpu_count 的设备ID"
                if [[ "$USE_OPEN_MODULES" == "true" ]]; then
                    has_incompatible_gpu=true
                fi
            fi
        fi
    done < <(lspci | grep -i nvidia)
    
    if [[ $gpu_count -eq 0 ]]; then
        exit_with_code $EXIT_NO_NVIDIA_GPU "未检测到NVIDIA GPU"
    fi
    
    # 处理兼容性问题
    if [[ "$USE_OPEN_MODULES" == "true" ]] && [[ "$has_incompatible_gpu" == "true" ]]; then
        echo
        log_error "检测到不兼容开源模块的GPU！"
        echo -e "${RED}开源模块支持情况：${NC}"
        echo "✅ 支持: Turing, Ampere, Ada Lovelace, Blackwell (RTX 16xx/20xx/30xx/40xx/50xx系列)"
        echo "❌ 不支持: Maxwell, Pascal, Volta (GTX 9xx/10xx系列, Tesla V100等)"
        echo

        if ! [[ "$AUTO_YES" == "true" ]]; then
            echo "解决方案："
            echo "1. 使用专有模块 (推荐)"
            echo "2. 仅针对兼容的GPU使用开源模块 (高级用户)"
            echo
            
            if confirm "是否切换到专有模块？" "Y"; then
                log_info "切换到专有内核模块"
                USE_OPEN_MODULES=false
            else
                log_warning "继续使用开源模块，但可能导致部分GPU无法正常工作"
            fi
        else
            # 自动化模式下的默认行为：切换到专有模块
            log_warning "自动化模式：切换到专有内核模块以确保兼容性"
            USE_OPEN_MODULES=false
        fi
    fi
    
    # 显示最终配置摘要
    echo
    log_info "GPU配置摘要:"
    printf "%-15s %-20s %-15s\n" "GPU编号" "架构" "模块类型"
    printf "%-15s %-20s %-15s\n" "-------" "--------" "--------"
    
    for i in "${!detected_architectures[@]}"; do
        local arch="${detected_architectures[$i]}"
        local module_type

        if [[ "$USE_OPEN_MODULES" == "true" ]]; then
            if is_open_module_supported "$arch"; then
                module_type="开源模块"
            else
                module_type="专有模块*"
            fi
        else
            module_type="专有模块"
        fi
        
        printf "%-15s %-20s %-15s\n" "#$((i+1))" "$arch" "$module_type"
    done
    
    if [ "$USE_OPEN_MODULES" = true ] && [ "$has_incompatible_gpu" = true ]; then
        echo
        log_warning "* 标记的GPU将回退到专有模块"
    fi
}

# 智能发行版版本检查
check_distro_support() {
    log_step "检查发行版支持情况..."
    
    local is_supported=true
    local support_level="full"  # full, partial, unsupported
    local warning_msg=""
    
    case $DISTRO_ID in
        rhel|rocky|ol|almalinux)
            case $DISTRO_VERSION in
                8|9|10) support_level="full" ;;
                7) support_level="partial"; warning_msg="RHEL 7 已EOL，建议升级" ;;
                *) support_level="unsupported"; warning_msg="不支持的RHEL版本: $DISTRO_VERSION" ;;
            esac
            ;;
        fedora)
            local version_num=${DISTRO_VERSION}
            if [[ $version_num -ge 39 && $version_num -le 42 ]]; then
                support_level="full"
            elif [[ $version_num -ge 35 && $version_num -lt 39 ]]; then
                support_level="partial"
                warning_msg="Fedora $DISTRO_VERSION 可能不是官方支持版本"
            else
                support_level="unsupported"
                warning_msg="Fedora $DISTRO_VERSION 可能不兼容"
            fi
            ;;
        ubuntu)
            case $DISTRO_VERSION in
                20.04|22.04|24.04) support_level="full" ;;
                18.04) support_level="partial"; warning_msg="Ubuntu 18.04 已EOL" ;;
                *) 
                    # 尝试从codename判断
                    if [[ -n "$DISTRO_CODENAME" ]]; then
                        case $DISTRO_CODENAME in
                            focal|jammy|noble) support_level="full" ;;
                            *) support_level="partial"; warning_msg="可能支持的Ubuntu版本: $DISTRO_VERSION ($DISTRO_CODENAME)" ;;
                        esac
                    else
                        support_level="partial"
                        warning_msg="未明确支持的Ubuntu版本: $DISTRO_VERSION"
                    fi
                    ;;
            esac
            ;;
        debian)
            case $DISTRO_VERSION in
                12) support_level="full" ;;
                11) support_level="partial"; warning_msg="Debian 11可能需要手动调整" ;;
                *) support_level="partial"; warning_msg="未明确支持的Debian版本: $DISTRO_VERSION" ;;
            esac
            ;;
        opensuse*|sles)
            if [[ "$DISTRO_VERSION" =~ ^15 ]]; then
                support_level="full"
            else
                support_level="partial"
                warning_msg="可能支持的SUSE版本: $DISTRO_VERSION"
            fi
            ;;
        amzn)
            case $DISTRO_VERSION in
                2023) support_level="full" ;;
                2) support_level="partial"; warning_msg="Amazon Linux 2可能需要调整" ;;
                *) support_level="unsupported"; warning_msg="不支持的Amazon Linux版本: $DISTRO_VERSION" ;;
            esac
            ;;
        azurelinux|mariner)
            case $DISTRO_VERSION in
                2.0|3.0) support_level="full" ;;
                *) support_level="partial"; warning_msg="可能支持的Azure Linux版本: $DISTRO_VERSION" ;;
            esac
            ;;
        kylin)
            case $DISTRO_VERSION in
                10) support_level="full" ;;
                *) support_level="partial"; warning_msg="可能支持的KylinOS版本: $DISTRO_VERSION" ;;
            esac
            ;;
        *)
            support_level="unsupported"
            warning_msg="未知或不支持的发行版: $DISTRO_ID"
            ;;
    esac
    
    # 输出支持状态
    case $support_level in
        "full")
            log_success "发行版完全支持: $DISTRO_ID $DISTRO_VERSION"
            ;;
        "partial")
            log_warning "发行版部分支持: $warning_msg"
            if ! confirm "是否继续安装？" "N"; then
                exit_with_code $EXIT_USER_CANCELLED "用户取消安装"
            fi
            ;;
        "unsupported")
            log_error "发行版不支持: $warning_msg"
            echo
            echo "支持的发行版："
            echo "- RHEL/Rocky/Oracle Linux: 8, 9, 10"
            echo "- Fedora: 39-42"
            echo "- Ubuntu: 20.04, 22.04, 24.04"
            echo "- Debian: 12"
            echo "- SUSE: 15.x"
            echo "- Amazon Linux: 2023"
            echo "- Azure Linux: 2.0, 3.0"
            echo "- KylinOS: 10"
            echo
            if ! confirm "是否强制继续安装？" "N"; then
                exit_with_code $EXIT_UNSUPPORTED_VERSION "不支持的发行版版本: $DISTRO_ID $DISTRO_VERSION"
            fi
            log_warning "强制安装模式，可能遇到兼容性问题"
            ;;
    esac
}

# 检查现有NVIDIA驱动安装
check_existing_nvidia_installation() {
    if [[ "$SKIP_EXISTING_CHECKS" == "true" ]]; then
        log_info "跳过现有驱动检查"
        return 0
    fi
    
    log_step "检查现有NVIDIA驱动安装..."
    
    local existing_driver=""
    local installation_method=""
    
    # 检查是否有NVIDIA内核模块
    if lsmod | grep -q nvidia; then
        existing_driver="kernel_module"
        log_warning "检测到已加载的NVIDIA内核模块："
        lsmod | grep nvidia
    fi
    
    # 检查包管理器安装的驱动
    case $DISTRO_ID in
        ubuntu|debian)
            if dpkg -l | grep -q nvidia-driver; then
                existing_driver="package_manager"
                installation_method="apt/dpkg"
                log_warning "检测到通过包管理器安装的NVIDIA驱动："
                dpkg -l | grep nvidia-driver
            fi
            ;;
        rhel|rocky|ol|almalinux|fedora|kylin|amzn)
            if rpm -qa | grep -q nvidia-driver; then
                existing_driver="package_manager"
                installation_method="dnf/rpm"
                log_warning "检测到通过包管理器安装的NVIDIA驱动："
                rpm -qa | grep nvidia
            fi
            ;;
        opensuse*|sles)
            if zypper search -i | grep -q nvidia; then
                existing_driver="package_manager"
                installation_method="zypper"
                log_warning "检测到通过包管理器安装的NVIDIA驱动："
                zypper search -i | grep nvidia
            fi
            ;;
    esac
    
    # 检查runfile安装
    if [[ -f /usr/bin/nvidia-uninstall ]]; then
        existing_driver="runfile"
        installation_method="runfile"
        log_warning "检测到通过runfile安装的NVIDIA驱动"
    fi
    
    # 检查其他PPA或第三方源
    case $DISTRO_ID in
        ubuntu)
            if apt-cache policy | grep -q "graphics-drivers"; then
                log_warning "检测到graphics-drivers PPA"
                installation_method="${installation_method:+$installation_method, }graphics-drivers PPA"
            fi
            ;;
        fedora)
            if dnf repolist | grep -q rpmfusion; then
                log_warning "检测到RPM Fusion仓库"
                installation_method="${installation_method:+$installation_method, }RPM Fusion"
            fi
            ;;
    esac
    
    # 处理现有安装 (支持自动化)
    if [[ -n "$existing_driver" ]]; then
        echo
        log_error "检测到现有NVIDIA驱动安装！"
        echo "安装方法: $installation_method"
        echo

        if ! [[ "$FORCE_REINSTALL" == "true" ]] && ! [[ "$AUTO_YES" == "true" ]]; then
            echo "建议操作："
            echo "1. 卸载现有驱动后重新安装 (推荐)"
            echo "2. 强制重新安装 (可能导致冲突)"
            echo "3. 跳过检查继续安装 (高级用户)"
            echo "4. 退出安装"
            echo
            
            local choice=$(select_option "请选择操作" "1" \
                "卸载现有驱动后重新安装" \
                "强制重新安装" \
                "跳过检查继续安装" \
                "退出安装")
            
            case $choice in
                1)
                    uninstall_existing_nvidia_driver "$existing_driver"
                    ;;
                2)
                    log_warning "强制重新安装模式"
                    FORCE_REINSTALL=true
                    ;;
                3)
                    log_warning "跳过现有驱动检查"
                    SKIP_EXISTING_CHECKS=true
                    ;;
                4)
                    exit_with_code $EXIT_EXISTING_DRIVER_USER_EXIT "用户选择退出以处理现有驱动"
                    ;;
            esac
        elif [[ "$AUTO_YES" == "true" ]] && ! [[ "$FORCE_REINSTALL" == "true" ]]; then
            # 自动化模式下的默认行为：卸载现有驱动
            log_warning "自动化模式：卸载现有驱动后重新安装"
            uninstall_existing_nvidia_driver "$existing_driver"
        else
            log_warning "强制重新安装模式，跳过现有驱动处理"
        fi
    else
        log_success "未检测到现有NVIDIA驱动"
    fi
}

# 卸载现有NVIDIA驱动
uninstall_existing_nvidia_driver() {
    local driver_type="$1"
    
    log_step "卸载现有NVIDIA驱动..."
    
    case $driver_type in
        "runfile")
            if [[ -f /usr/bin/nvidia-uninstall ]]; then
                log_info "使用nvidia-uninstall卸载runfile安装的驱动"
                /usr/bin/nvidia-uninstall --silent || log_warning "runfile卸载可能不完整"
            fi
            ;;
        "package_manager")
            case $DISTRO_ID in
                ubuntu|debian)
                    apt remove --purge -y nvidia-* libnvidia-* || true
                    apt autoremove -y || true
                    ;;
                rhel|rocky|ol|almalinux|fedora|kylin|amzn)
                    if dnf --version &>/dev/null; then
                        dnf remove -y nvidia-* libnvidia-* || true
                        dnf autoremove -y || true
                    else
                        yum remove -y nvidia-* libnvidia-* || true
                    fi
                    ;;
                opensuse*|sles)
                    zypper remove -y nvidia-* || true
                    ;;
            esac
            ;;
    esac
    
    # 清理模块
    if lsmod | grep -q nvidia; then
        log_info "卸载NVIDIA内核模块"
        rmmod nvidia_drm nvidia_modeset nvidia_uvm nvidia || log_warning "部分模块卸载失败，需要重启"
    fi
    
    # 清理配置文件
    rm -rf /etc/modprobe.d/*nvidia* /etc/X11/xorg.conf.d/*nvidia* || true
    
    log_success "现有驱动卸载完成"
}

# 检测Secure Boot状态
check_secure_boot() {
    log_step "检测UEFI Secure Boot状态..."
    
    local secure_boot_enabled=false
    local secure_boot_method=""
    
    # 方法1: 检查/sys/firmware/efi/efivars
    if [[ -d /sys/firmware/efi/efivars ]]; then
        if [[ -f /sys/firmware/efi/efivars/SecureBoot-* ]]; then
            local secure_boot_value=$(od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | tr -d ' ')
            if [[ "$secure_boot_value" =~ 1$ ]]; then
                secure_boot_enabled=true
                secure_boot_method="efivars"
            fi
        fi
    fi
    
    # 方法2: 使用mokutil命令
    if command -v mokutil &>/dev/null; then
        if mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
            secure_boot_enabled=true
            secure_boot_method="mokutil"
        fi
    fi
    
    # 方法3: 检查bootctl命令
    if command -v bootctl &>/dev/null; then
        if bootctl status 2>/dev/null | grep -q "Secure Boot: enabled"; then
            secure_boot_enabled=true
            secure_boot_method="bootctl"
        fi
    fi
    
    # 方法4: 检查dmesg输出
    if dmesg | grep -q "Secure boot enabled"; then
        secure_boot_enabled=true
        secure_boot_method="dmesg"
    fi
    
    log_debug "Secure Boot检测方法: $secure_boot_method"
    
    if [[ "$secure_boot_enabled" == "true" ]]; then
        handle_secure_boot_enabled
    else
        log_success "Secure Boot未启用或系统不支持UEFI"
    fi
}

# 处理Secure Boot启用的情况
handle_secure_boot_enabled() {
    echo
    echo -e "${RED}██████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}██                          ⚠️  致命警告  ⚠️                            ██${NC}"
    echo -e "${RED}██████████████████████████████████████████████████████████████████████████████${NC}"
    echo
    log_error "检测到UEFI Secure Boot已启用！"
    echo
    echo -e "${YELLOW}🚨 为什么这是个问题？${NC}"
    echo "1. Secure Boot阻止加载未签名的内核模块"
    echo "2. NVIDIA驱动包含内核模块，必须正确签名才能加载"
    echo "3. 即使安装成功，驱动也无法工作，导致："
    echo "   • 黑屏或图形显示异常"
    echo "   • CUDA/OpenCL不可用"
    echo "   • 多显示器不工作"
    echo "   • 系统可能无法启动"
    echo
    echo -e "${GREEN}✅ 推荐解决方案（选择其一）：${NC}"
    echo
    echo -e "${BLUE}方案1: 禁用Secure Boot (最简单)${NC}"
    echo "1. 重启进入BIOS/UEFI设置"
    echo "2. 找到Security或Boot选项"
    echo "3. 禁用Secure Boot"
    echo "4. 保存并重启"
    echo "5. 重新运行此脚本"
    echo
    echo -e "${BLUE}方案2: 使用MOK密钥签名 (保持Secure Boot)${NC}"
    echo "1. 安装必要工具: mokutil, openssl, dkms"
    echo "2. 生成Machine Owner Key (MOK)"
    echo "3. 将MOK注册到UEFI固件"
    echo "4. 配置DKMS自动签名NVIDIA模块"
    echo "5. 重新运行此脚本"
    echo
    echo -e "${BLUE}方案3: 使用预签名驱动 (如果可用)${NC}"
    echo "某些发行版提供预签名的NVIDIA驱动："
    echo "• Ubuntu: 可能通过ubuntu-drivers获得签名驱动"
    echo "• RHEL: 可能有预编译的签名模块"
    echo "• SUSE: 可能通过官方仓库获得"
    echo
    echo -e "${YELLOW}🔧 自动配置MOK密钥 (高级选项)${NC}"
    echo "此脚本可以帮助配置MOK密钥，但需要："
    echo "• 在重启时手动确认MOK密钥"
    echo "• 记住设置的密码"
    echo "• 理解Secure Boot的安全影响"
    echo
    
    # 检查是否已有MOK密钥
    local has_existing_mok=false
    if [[ -f /var/lib/shim-signed/mok/MOK.der ]] || [[ -f /var/lib/dkms/mok.pub ]]; then
        has_existing_mok=true
        echo -e "${GREEN}✓ 检测到现有MOK密钥文件${NC}"
    fi
    
    echo -e "${RED}██████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}██  强烈建议: 在解决Secure Boot问题之前，不要继续安装NVIDIA驱动！   ██${NC}"
    echo -e "${RED}██████████████████████████████████████████████████████████████████████████████${NC}"
    echo

    if ! [[ "$AUTO_YES" == "true" ]]; then
        echo "请选择操作："
        echo "1. 退出安装，我将手动解决Secure Boot问题"
        echo "2. 帮助配置MOK密钥 (高级用户)"
        echo "3. 强制继续安装 (不推荐，可能导致系统问题)"
        echo
        
        local choice=$(select_option "请选择" "1" \
            "退出安装" \
            "配置MOK密钥" \
            "强制继续安装")
        
        case $choice in
            1)
                log_info "安装已取消，请解决Secure Boot问题后重新运行"
                echo
                echo "有用的命令："
                echo "• 检查Secure Boot状态: mokutil --sb-state"
                echo "• 检查现有MOK: mokutil --list-enrolled"
                echo "• 检查NVIDIA模块: lsmod | grep nvidia"
                echo
                exit_with_code $EXIT_SECURE_BOOT_USER_EXIT "用户选择退出以处理Secure Boot问题"
                ;;
            2)
                setup_mok_signing
                ;;
            3)
                log_warning "用户选择强制继续安装，可能导致驱动无法工作"
                ;;
        esac
    else
        # 自动化模式下的行为
        if [[ "$has_existing_mok" == "true" ]]; then
            log_warning "自动化模式：检测到现有MOK密钥，继续安装"
        else
            exit_with_code $EXIT_SECURE_BOOT_AUTO_FAILED "自动化模式下无法处理Secure Boot问题"
        fi
    fi
}

# 设置MOK密钥签名
setup_mok_signing() {
    log_step "配置MOK密钥签名..."
    
    # 检查必要工具
    local missing_tools=()
    for tool in mokutil openssl; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "缺少必要工具: ${missing_tools[*]}"
        echo "请先安装这些工具："
        case $DISTRO_ID in
            ubuntu|debian)
                echo "sudo apt install mokutil openssl"
                ;;
            rhel|rocky|ol|almalinux|fedora)
                echo "sudo dnf install mokutil openssl"
                ;;
            opensuse*|sles)
                echo "sudo zypper install mokutil openssl"
                ;;
        esac
        exit_with_code $EXIT_MOK_TOOLS_MISSING "缺少MOK管理工具: ${missing_tools[*]}"
    fi
    
    # 检查是否已有MOK密钥
    local mok_key_path=""
    local mok_cert_path=""
    
    # Ubuntu/Debian路径
    if [[ -f /var/lib/shim-signed/mok/MOK.priv ]] && [[ -f /var/lib/shim-signed/mok/MOK.der ]]; then
        mok_key_path="/var/lib/shim-signed/mok/MOK.priv"
        mok_cert_path="/var/lib/shim-signed/mok/MOK.der"
        log_info "使用现有Ubuntu/Debian MOK密钥"
    # DKMS路径
    elif [[ -f /var/lib/dkms/mok.key ]] && [[ -f /var/lib/dkms/mok.der ]]; then
        mok_key_path="/var/lib/dkms/mok.key"
        mok_cert_path="/var/lib/dkms/mok.der"
        log_info "使用现有DKMS MOK密钥"
    else
        # 生成新的MOK密钥
        log_info "生成新的MOK密钥..."
        
        # 创建目录
        mkdir -p /var/lib/dkms
        
        # 生成密钥和证书
        if ! openssl req -new -x509 \
            -newkey rsa:2048 \
            -keyout /var/lib/dkms/mok.key \
            -outform DER \
            -out /var/lib/dkms/mok.der \
            -nodes -days 36500 \
            -subj "/CN=NVIDIA Driver MOK Signing Key"; then
            exit_with_code $EXIT_MOK_OPERATION_FAILED "MOK密钥生成失败"
        fi
        
        # 也生成PEM格式的公钥供参考
        openssl x509 -in /var/lib/dkms/mok.der -inform DER -out /var/lib/dkms/mok.pub -outform PEM
        
        mok_key_path="/var/lib/dkms/mok.key"
        mok_cert_path="/var/lib/dkms/mok.der"
        
        log_success "MOK密钥生成完成"
    fi
    
    # 注册MOK密钥
    log_info "注册MOK密钥到UEFI固件..."
    echo
    echo -e "${YELLOW}重要说明：${NC}"
    echo "1. 系统将提示您输入一个一次性密码"
    echo "2. 请记住这个密码，重启时需要使用"
    echo "3. 建议使用简单的数字密码（考虑键盘布局）"
    echo
    
    if ! mokutil --import "$mok_cert_path"; then
        exit_with_code $EXIT_MOK_OPERATION_FAILED "MOK密钥注册失败"
    fi
    
    log_success "MOK密钥已排队等待注册"
    echo
    echo -e "${GREEN}下一步操作：${NC}"
    echo "1. 脚本安装完成后，系统将重启"
    echo "2. 重启时会出现MOK Manager界面"
    echo "3. 选择 'Enroll MOK'"
    echo "4. 选择 'Continue'"
    echo "5. 选择 'Yes'"
    echo "6. 输入刚才设置的密码"
    echo "7. 系统将再次重启"
    echo
    echo -e "${YELLOW}注意：MOK Manager界面可能使用英文，请仔细操作${NC}"
    
    # 配置DKMS自动签名
    configure_dkms_signing "$mok_key_path" "$mok_cert_path"
}

# 配置DKMS自动签名
configure_dkms_signing() {
    local key_path="$1"
    local cert_path="$2"
    
    log_info "配置DKMS自动签名..."
    
    # 配置DKMS签名工具
    if [[ -f /etc/dkms/framework.conf ]]; then
        # 启用签名工具
        if grep -q "^#sign_tool" /etc/dkms/framework.conf; then
            sed -i 's/^#sign_tool/sign_tool/' /etc/dkms/framework.conf
        elif ! grep -q "^sign_tool" /etc/dkms/framework.conf; then
            echo 'sign_tool="/etc/dkms/sign_helper.sh"' >> /etc/dkms/framework.conf
        fi
    fi
    
    # 创建签名脚本
    cat > /etc/dkms/sign_helper.sh << EOF
#!/bin/sh
/lib/modules/"\$1"/build/scripts/sign-file sha512 "$key_path" "$cert_path" "\$2"
EOF
    
    chmod +x /etc/dkms/sign_helper.sh
    
    # 为NVIDIA特定配置
    echo "SIGN_TOOL=\"/etc/dkms/sign_helper.sh\"" > /etc/dkms/nvidia.conf
    
    save_rollback_info "rm -f /etc/dkms/sign_helper.sh /etc/dkms/nvidia.conf"
    
    log_success "DKMS自动签名配置完成"
}

# 预安装检查集合
pre_installation_checks() {
    log_step "执行预安装检查..."
    
    # 检查Secure Boot状态
    check_secure_boot
    
    # 检查根分区空间
    local root_space=$(df / | awk 'NR==2 {print $4}')
    if [[ $root_space -lt 1048576 ]]; then  # 1GB
        log_warning "根分区可用空间不足1GB，可能影响安装"
    fi
    
    # 检查是否在虚拟机中运行
    if systemd-detect-virt --quiet; then
        local virt_type=$(systemd-detect-virt)
        log_warning "检测到虚拟机环境: $virt_type"
        echo "注意事项："
        echo "• 确保虚拟机已启用3D加速"
        echo "• 某些虚拟机可能不支持NVIDIA GPU直通"
        echo "• 容器环境可能需要特殊配置"
    fi
    
    # 检查是否有自定义内核
    local kernel_version=$(uname -r)
    if [[ "$kernel_version" =~ (custom|zen|liquorix) ]]; then
        log_warning "检测到自定义内核: $kernel_version"
        echo "自定义内核可能需要额外的DKMS配置"
    fi
    
    log_success "预安装检查完成"
}

# 获取发行版特定的变量
get_distro_vars() {
    case $DISTRO_ID in
        rhel|rocky|ol|almalinux)
            if [[ "$DISTRO_VERSION" == "10" ]]; then
                DISTRO_REPO="rhel10"
            elif [[ "$DISTRO_VERSION" == "9" ]]; then
                DISTRO_REPO="rhel9"
            elif [[ "$DISTRO_VERSION" == "8" ]]; then
                DISTRO_REPO="rhel8"
            fi
            ARCH_EXT="x86_64"
            ;;
        fedora)
            DISTRO_REPO="fedora${DISTRO_VERSION}"
            ARCH_EXT="x86_64"
            ;;
        ubuntu)
            DISTRO_REPO="ubuntu${DISTRO_VERSION//.}"
            ARCH_EXT="amd64"
            ;;
        debian)
            DISTRO_REPO="debian${DISTRO_VERSION}"
            ARCH_EXT="amd64"
            ;;
        opensuse*)
            DISTRO_REPO="opensuse15"
            ARCH_EXT="x86_64"
            ;;
        sles)
            DISTRO_REPO="sles15"
            ARCH_EXT="x86_64"
            ;;
        amzn)
            DISTRO_REPO="amzn2023"
            ARCH_EXT="x86_64"
            ;;
        azurelinux)
            DISTRO_REPO="azl3"
            ARCH_EXT="x86_64"
            ;;
        mariner)
            DISTRO_REPO="cm2"
            ARCH_EXT="x86_64"
            ;;
        kylin)
            DISTRO_REPO="kylin10"
            ARCH_EXT="x86_64"
            ;;
    esac
}

safe_add_repository() {
    local repo_type="$1"
    local repo_url="$2"
    local repo_name="$3"
    local key_url="$4"
    
    case $repo_type in
        "dnf")
            if dnf repolist | grep -q "$repo_name"; then
                log_info "仓库 $repo_name 已存在，跳过添加"
            else
                log_info "添加DNF仓库: $repo_name"
                dnf config-manager --add-repo "$repo_url"
                save_rollback_info "dnf config-manager --remove-repo $repo_name"
            fi
            ;;
        "apt")
            if [[ -f "/etc/apt/sources.list.d/$repo_name.list" ]] || grep -q "$repo_url" /etc/apt/sources.list.d/*.list 2>/dev/null; then
                log_info "APT仓库已存在，跳过添加"
            else
                log_info "添加APT仓库: $repo_name"
                if [[ -n "$key_url" ]]; then
                    wget -qO- "$key_url" | gpg --dearmor > "/usr/share/keyrings/$repo_name-keyring.gpg"
                    echo "deb [signed-by=/usr/share/keyrings/$repo_name-keyring.gpg] $repo_url" > "/etc/apt/sources.list.d/$repo_name.list"
                    save_rollback_info "rm -f /etc/apt/sources.list.d/$repo_name.list /usr/share/keyrings/$repo_name-keyring.gpg"
                else
                    echo "deb $repo_url" > "/etc/apt/sources.list.d/$repo_name.list"
                    save_rollback_info "rm -f /etc/apt/sources.list.d/$repo_name.list"
                fi
            fi
            ;;
        "zypper")
            if zypper lr | grep -q "$repo_name"; then
                log_info "Zypper仓库 $repo_name 已存在，跳过添加"
            else
                log_info "添加Zypper仓库: $repo_name"
                zypper addrepo "$repo_url" "$repo_name"
                save_rollback_info "zypper removerepo $repo_name"
            fi
            ;;
    esac
}

safe_install_package() {
    local package_manager="$1"
    shift
    local packages=("$@")
    
    local missing_packages=()
    
    # 检查哪些包未安装
    case $package_manager in
        "dnf"|"yum")
            for pkg in "${packages[@]}"; do
                if ! rpm -q "$pkg" &>/dev/null; then
                    missing_packages+=("$pkg")
                fi
            done
            ;;
        "apt")
            for pkg in "${packages[@]}"; do
                if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
                    missing_packages+=("$pkg")
                fi
            done
            ;;
        "zypper")
            for pkg in "${packages[@]}"; do
                if ! zypper search -i "$pkg" | grep -q "^i"; then
                    missing_packages+=("$pkg")
                fi
            done
            ;;
        "tdnf")
            for pkg in "${packages[@]}"; do
                if ! tdnf list installed "$pkg" &>/dev/null; then
                    missing_packages+=("$pkg")
                fi
            done
            ;;
    esac
    
    # 只安装缺失的包
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        log_info "安装缺失的包: ${missing_packages[*]}"
        case $package_manager in
            "dnf")
                dnf install -y "${missing_packages[@]}"
                ;;
            "yum")
                yum install -y "${missing_packages[@]}"
                ;;
            "apt")
                apt install -y "${missing_packages[@]}"
                ;;
            "zypper")
                zypper install -y "${missing_packages[@]}"
                ;;
            "tdnf")
                tdnf install -y "${missing_packages[@]}"
                ;;
        esac
        
        # 保存回滚信息
        for pkg in "${missing_packages[@]}"; do
            save_rollback_info "$package_manager remove -y $pkg"
        done
    else
        log_info "所有包已安装，跳过安装步骤"
    fi
}

# 启用第三方仓库和依赖
enable_repositories() {
    if is_step_completed "enable_repositories"; then
        log_info "第三方仓库已启用，跳过此步骤"
        return 0
    fi
    
    log_step "启用必要的仓库和依赖..."
    
    case $DISTRO_ID in
        rhel)
            # RHEL需要subscription-manager启用仓库
            if [[ "$DISTRO_VERSION" == "10" ]]; then
                subscription-manager repos --enable=rhel-10-for-${ARCH}-appstream-rpms || log_warning "无法启用appstream仓库"
                subscription-manager repos --enable=rhel-10-for-${ARCH}-baseos-rpms || log_warning "无法启用baseos仓库"
                subscription-manager repos --enable=codeready-builder-for-rhel-10-${ARCH}-rpms || log_warning "无法启用codeready-builder仓库"
                
                # 安装EPEL
                if ! rpm -q epel-release &>/dev/null; then
                    dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm
                    save_rollback_info "dnf remove -y epel-release"
                fi
            elif [[ "$DISTRO_VERSION" == "9" ]]; then
                subscription-manager repos --enable=rhel-9-for-${ARCH}-appstream-rpms || log_warning "无法启用appstream仓库"
                subscription-manager repos --enable=rhel-9-for-${ARCH}-baseos-rpms || log_warning "无法启用baseos仓库"
                subscription-manager repos --enable=codeready-builder-for-rhel-9-${ARCH}-rpms || log_warning "无法启用codeready-builder仓库"
                
                if ! rpm -q epel-release &>/dev/null; then
                    dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
                    save_rollback_info "dnf remove -y epel-release"
                fi
            elif [[ "$DISTRO_VERSION" == "8" ]]; then
                subscription-manager repos --enable=rhel-8-for-${ARCH}-appstream-rpms || log_warning "无法启用appstream仓库"
                subscription-manager repos --enable=rhel-8-for-${ARCH}-baseos-rpms || log_warning "无法启用baseos仓库"
                subscription-manager repos --enable=codeready-builder-for-rhel-8-${ARCH}-rpms || log_warning "无法启用codeready-builder仓库"
                
                if ! rpm -q epel-release &>/dev/null; then
                    dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
                    save_rollback_info "dnf remove -y epel-release"
                fi
            fi
            ;;
        rocky)
            if [[ "$DISTRO_VERSION" =~ ^(9|10) ]]; then
                if ! dnf repolist enabled | grep -q crb; then
                    dnf config-manager --set-enabled crb
                    save_rollback_info "dnf config-manager --set-disabled crb"
                fi
                safe_install_package "dnf" epel-release
            elif [[ "$DISTRO_VERSION" == "8" ]]; then
                if ! dnf repolist enabled | grep -q powertools; then
                    dnf config-manager --set-enabled powertools
                    save_rollback_info "dnf config-manager --set-disabled powertools"
                fi
                safe_install_package "dnf" epel-release
            fi
            ;;
        ol)
            if [[ "$DISTRO_VERSION" == "10" ]]; then
                if ! dnf repolist enabled | grep -q ol10_codeready_builder; then
                    dnf config-manager --set-enabled ol10_codeready_builder
                    save_rollback_info "dnf config-manager --set-disabled ol10_codeready_builder"
                fi
                safe_install_package "dnf" oracle-epel-release-el10
            elif [[ "$DISTRO_VERSION" == "9" ]]; then
                if ! dnf repolist enabled | grep -q ol9_codeready_builder; then
                    dnf config-manager --set-enabled ol9_codeready_builder
                    save_rollback_info "dnf config-manager --set-disabled ol9_codeready_builder"
                fi
                safe_install_package "dnf" oracle-epel-release-el9
            elif [[ "$DISTRO_VERSION" == "8" ]]; then
                if ! dnf repolist enabled | grep -q ol8_codeready_builder; then
                    dnf config-manager --set-enabled ol8_codeready_builder
                    save_rollback_info "dnf config-manager --set-disabled ol8_codeready_builder"
                fi
                safe_install_package "dnf" oracle-epel-release-el8
            fi
            ;;
        debian)
            # 启用contrib仓库
            if ! grep -q "contrib" /etc/apt/sources.list; then
                if ! is_step_completed "debian_contrib_enabled"; then
                    add-apt-repository -y contrib
                    save_state "debian_contrib_enabled"
                    save_rollback_info "add-apt-repository -r contrib"
                fi
            fi
            
            if ! is_step_completed "apt_update_after_contrib"; then
                apt update
                save_state "apt_update_after_contrib"
            fi
            ;;
        opensuse*|sles)
            # 启用PackageHub
            if command -v SUSEConnect >/dev/null 2>&1 && ! SUSEConnect -l | grep -q PackageHub; then
                SUSEConnect --product PackageHub/15/$(uname -m) || log_warning "无法启用PackageHub"
                save_rollback_info "SUSEConnect -d --product PackageHub/15/$(uname -m)"
            fi
            
            if ! is_step_completed "zypper_refresh_after_packagehub"; then
                zypper refresh
                save_state "zypper_refresh_after_packagehub"
            fi
            ;;
        azurelinux)
            safe_install_package "tdnf" azurelinux-repos-extended
            ;;
        mariner)
            safe_install_package "tdnf" mariner-repos-extended
            ;;
    esac
    
    save_state "enable_repositories"
}

# 安装内核头文件和开发包
install_kernel_headers() {
    if is_step_completed "install_kernel_headers"; then
        log_info "内核头文件已安装，跳过此步骤"
        return 0
    fi
    
    log_step "安装内核头文件和开发包..."
    
    local kernel_version=$(uname -r)
    
    case $DISTRO_ID in
        rhel|rocky|ol|almalinux)
            if [[ "$DISTRO_VERSION" =~ ^(9|10) ]]; then
                safe_install_package "dnf" kernel-devel-matched kernel-headers
            else
                safe_install_package "dnf" "kernel-devel-$(uname -r)" kernel-headers
            fi
            ;;
        fedora)
            safe_install_package "dnf" kernel-devel-matched kernel-headers
            ;;
        ubuntu|debian)
            if ! is_step_completed "apt_update_before_headers"; then
                apt update
                save_state "apt_update_before_headers"
            fi
            safe_install_package "apt" "linux-headers-$(uname -r)"
            ;;
        opensuse*|sles)
            local variant=$(uname -r | grep -o '\-[^-]*' | sed 's/^-//')
            local version=$(uname -r | sed 's/\-[^-]*$//')
            safe_install_package "zypper" "kernel-${variant:-default}-devel=${version}"
            ;;
        amzn)
            safe_install_package "dnf" "kernel-devel-$(uname -r)" "kernel-headers-$(uname -r)"
            ;;
        azurelinux|mariner)
            safe_install_package "tdnf" "kernel-devel-$(uname -r)" "kernel-headers-$(uname -r)" "kernel-modules-extra-$(uname -r)"
            ;;
        kylin)
            safe_install_package "dnf" "kernel-devel-$(uname -r)" kernel-headers
            ;;
    esac
    
    save_state "install_kernel_headers"
}

# 安装本地仓库
install_local_repository() {
    log_info "设置本地仓库安装..."
    
    local version=${DRIVER_VERSION:-"latest"}
    local base_url="https://developer.download.nvidia.com/compute/nvidia-driver"
    
    case $DISTRO_ID in
        rhel|rocky|ol|almalinux|fedora|amzn|azurelinux|mariner|kylin)
            local rpm_file="nvidia-driver-local-repo-${DISTRO_REPO}.${version}.${ARCH_EXT}.rpm"
            log_info "下载本地仓库包: $rpm_file"
            wget -O /tmp/$rpm_file "${base_url}/${version}/local_installers/${rpm_file}"
            rpm --install /tmp/$rpm_file
            ;;
        ubuntu|debian)
            local deb_file="nvidia-driver-local-repo-${DISTRO_REPO}-${version}_${ARCH_EXT}.deb"
            log_info "下载本地仓库包: $deb_file"
            wget -O /tmp/$deb_file "${base_url}/${version}/local_installers/${deb_file}"
            dpkg -i /tmp/$deb_file
            apt update
            # 添加GPG密钥
            cp /var/nvidia-driver-local-repo-${DISTRO_REPO}-${version}/nvidia-driver-*-keyring.gpg /usr/share/keyrings/
            ;;
        opensuse*|sles)
            local rpm_file="nvidia-driver-local-repo-${DISTRO_REPO}.${version}.${ARCH_EXT}.rpm"
            log_info "下载本地仓库包: $rpm_file"
            wget -O /tmp/$rpm_file "${base_url}/${version}/local_installers/${rpm_file}"
            rpm --install /tmp/$rpm_file
            ;;
    esac
}

# 安装网络仓库 
install_network_repository() {
    log_info "设置网络仓库..."
    
    case $DISTRO_ID in
        rhel|rocky|ol|almalinux|fedora|amzn|kylin)
            local repo_url="https://developer.download.nvidia.com/compute/cuda/repos/${DISTRO_REPO}/${ARCH}/cuda-${DISTRO_REPO}.repo"
            safe_add_repository "dnf" "$repo_url" "cuda-${DISTRO_REPO}"
            
            # 清理缓存
            if ! is_step_completed "dnf_cache_cleared"; then
                dnf clean expire-cache
                save_state "dnf_cache_cleared"
            fi
            ;;
        ubuntu|debian)
            # 检查并安装cuda-keyring
            if ! dpkg -l cuda-keyring &>/dev/null; then
                local keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/${DISTRO_REPO}/${ARCH}/cuda-keyring_1.1-1_all.deb"
                log_info "下载并安装cuda-keyring"
                wget -O /tmp/cuda-keyring.deb "$keyring_url"
                dpkg -i /tmp/cuda-keyring.deb
                save_rollback_info "dpkg -r cuda-keyring"
                rm -f /tmp/cuda-keyring.deb
            else
                log_info "cuda-keyring已安装，跳过"
            fi
            
            if ! is_step_completed "apt_update_after_repo"; then
                apt update
                save_state "apt_update_after_repo"
            fi
            ;;
        opensuse*|sles)
            local repo_url="https://developer.download.nvidia.com/compute/cuda/repos/${DISTRO_REPO}/${ARCH}/cuda-${DISTRO_REPO}.repo"
            safe_add_repository "zypper" "$repo_url" "cuda-${DISTRO_REPO}"
            
            if ! is_step_completed "zypper_refresh_after_repo"; then
                zypper refresh
                save_state "zypper_refresh_after_repo"
            fi
            ;;
        azurelinux|mariner)
            local repo_url="https://developer.download.nvidia.com/compute/cuda/repos/${DISTRO_REPO}/${ARCH}/cuda-${DISTRO_REPO}.repo"
            safe_add_repository "dnf" "$repo_url" "cuda-${DISTRO_REPO}"
            
            if ! is_step_completed "tdnf_cache_cleared"; then
                tdnf clean expire-cache
                save_state "tdnf_cache_cleared"
            fi
            ;;
    esac
}

# 添加NVIDIA官方仓库
add_nvidia_repository() {
    if is_step_completed "add_nvidia_repository"; then
        log_info "NVIDIA仓库已添加，跳过此步骤"
        return 0
    fi
    
    log_step "添加NVIDIA官方仓库..."
    
    get_distro_vars

    if [[ "$USE_LOCAL_REPO" == "true" ]]; then
        install_local_repository
    else
        install_network_repository
    fi
    
    save_state "add_nvidia_repository"
}

# 启用DNF模块 (RHEL 8/9特有)
enable_dnf_modules() {
    case $DISTRO_ID in
        rhel|rocky|ol|almalinux)
            if [[ "$DISTRO_VERSION" =~ ^(8|9) ]]; then
                log_step "启用DNF模块..."
                if [[ "$USE_OPEN_MODULES" == "true" ]]; then
                    dnf module enable -y nvidia-driver:open-dkms
                else
                    dnf module enable -y nvidia-driver:latest-dkms
                fi
            fi
            ;;
        kylin|amzn)
            log_step "启用DNF模块..."
            if [[ "$USE_OPEN_MODULES" == "true" ]]; then
                dnf module enable -y nvidia-driver:open-dkms
            else
                dnf module enable -y nvidia-driver:latest-dkms
            fi
            ;;
    esac
}

# 安装NVIDIA驱动
install_nvidia_driver() {
    log_step "安装NVIDIA驱动 ($(if $USE_OPEN_MODULES; then echo "开源模块"; else echo "专有模块"; fi), $INSTALL_TYPE)..."
    
    case $DISTRO_ID in
        rhel|rocky|ol|almalinux|fedora|kylin|amzn)
            install_nvidia_rpm
            ;;
        ubuntu|debian)
            install_nvidia_deb
            ;;
        opensuse*|sles)
            install_nvidia_suse
            ;;
        azurelinux|mariner)
            # Azure Linux只支持开源模块
            tdnf install -y nvidia-open
            ;;
    esac
}

# 安装RPM包
install_nvidia_rpm() {
    case $INSTALL_TYPE in
        full)
            if [[ "$USE_OPEN_MODULES" == "true" ]]; then
                if [[ "$DISTRO_ID" =~ ^(rhel|rocky|ol|almalinux)$ && "$DISTRO_VERSION" =~ ^(10)$ ]] || [[ "$DISTRO_ID" == "fedora" ]]; then
                    dnf install -y nvidia-open
                else
                    dnf install -y nvidia-open
                fi
            else
                dnf install -y cuda-drivers
            fi
            ;;
        compute-only)
            if [[ "$USE_OPEN_MODULES" == "true" ]]; then
                dnf install -y nvidia-driver-cuda kmod-nvidia-open-dkms
            else
                dnf install -y nvidia-driver-cuda kmod-nvidia-latest-dkms
            fi
            ;;
        desktop-only)
            if [[ "$USE_OPEN_MODULES" == "true" ]]; then
                dnf install -y nvidia-driver kmod-nvidia-open-dkms
            else
                dnf install -y nvidia-driver kmod-nvidia-latest-dkms
            fi
            ;;
    esac
}

# 安装DEB包
install_nvidia_deb() {
    case $INSTALL_TYPE in
        full)
            if [[ "$USE_OPEN_MODULES" == "true" ]]; then
                apt install -y nvidia-open
            else
                apt install -y cuda-drivers
            fi
            ;;
        compute-only)
            if [[ "$USE_OPEN_MODULES" == "true" ]]; then
                apt install -y nvidia-driver-cuda nvidia-kernel-open-dkms
            else
                apt install -y nvidia-driver-cuda nvidia-kernel-dkms
            fi
            ;;
        desktop-only)
            if [[ "$USE_OPEN_MODULES" == "true" ]]; then
                apt install -y nvidia-driver nvidia-kernel-open-dkms
            else
                apt install -y nvidia-driver nvidia-kernel-dkms
            fi
            ;;
    esac
}

# 安装SUSE包
install_nvidia_suse() {
    case $INSTALL_TYPE in
        full)
            if [[ "$USE_OPEN_MODULES" == "true" ]]; then
                zypper -v install nvidia-open
            else
                zypper -v install cuda-drivers
            fi
            ;;
        compute-only)
            if [[ "$USE_OPEN_MODULES" == "true" ]]; then
                zypper -v install nvidia-compute-G06 nvidia-open-driver-G06
            else
                zypper -v install nvidia-compute-G06 nvidia-driver-G06
            fi
            ;;
        desktop-only)
            if [[ "$USE_OPEN_MODULES" == "true" ]]; then
                zypper -v install nvidia-video-G06 nvidia-open-driver-G06
            else
                zypper -v install nvidia-video-G06 nvidia-driver-G06
            fi
            ;;
    esac
}

# 禁用nouveau驱动
disable_nouveau() {
    log_step "禁用nouveau开源驱动..."
    
    # 创建黑名单文件
    cat > /etc/modprobe.d/blacklist-nvidia-nouveau.conf << EOF
blacklist nouveau
options nouveau modeset=0
EOF
    
    # 更新initramfs
    case $DISTRO_ID in
        ubuntu|debian)
            update-initramfs -u
            ;;
        rhel|rocky|ol|almalinux|fedora|kylin|amzn)
            if command -v dracut &> /dev/null; then
                dracut -f
            fi
            ;;
        opensuse*|sles)
            mkinitrd
            ;;
        azurelinux|mariner)
            if command -v dracut &> /dev/null; then
                dracut -f
            fi
            ;;
    esac
}

# 启用persistence daemon
enable_persistence_daemon() {
    log_step "启用NVIDIA persistence daemon..."
    
    if systemctl list-unit-files | grep -q nvidia-persistenced; then
        systemctl enable nvidia-persistenced
        log_success "NVIDIA persistence daemon已启用"
    else
        log_warning "nvidia-persistenced服务未找到"
    fi
}

# 验证安装
verify_installation() {
    log_step "验证NVIDIA驱动安装..."
    
    # 检查驱动版本
    if [[ -f /proc/driver/nvidia/version ]]; then
        local driver_version=$(cat /proc/driver/nvidia/version | head -1)
        log_success "NVIDIA驱动已加载: $driver_version"
    else
        log_warning "NVIDIA驱动模块未加载（可能需要重启）"
    fi
    
    # 检查nvidia-smi
    if command -v nvidia-smi &> /dev/null; then
        log_success "nvidia-smi工具可用"
        if nvidia-smi &> /dev/null; then
            echo
            nvidia-smi
        else
            log_warning "nvidia-smi执行失败（可能需要重启系统）"
        fi
    else
        log_warning "nvidia-smi命令不可用"
    fi
    
    # 检查模块类型
    if lsmod | grep -q nvidia; then
        local module_info=$(lsmod | grep nvidia | head -1)
        log_info "已加载的NVIDIA模块: $module_info"
        
        # 检查是否是开源模块
        if [[ -f /sys/module/nvidia/version ]]; then
            local module_version=$(cat /sys/module/nvidia/version 2>/dev/null || echo "未知")
            log_info "模块版本: $module_version"
        fi
    fi
}

# 清理安装文件
cleanup() {
    log_step "清理安装文件..."

    if [[ "$USE_LOCAL_REPO" == "true" ]]; then
        case $DISTRO_ID in
            rhel|rocky|ol|almalinux|fedora|kylin|amzn)
                dnf remove -y nvidia-driver-local-repo-* 2>/dev/null || true
                ;;
            ubuntu|debian)
                apt remove --purge -y nvidia-driver-local-repo-* 2>/dev/null || true
                ;;
            opensuse*|sles)
                zypper remove -y nvidia-driver-local-repo-* 2>/dev/null || true
                ;;
            azurelinux|mariner)
                tdnf remove -y nvidia-driver-local-repo-* 2>/dev/null || true
                ;;
        esac
    fi
    
    # 清理下载的文件
    cleanup_temp_files
    
    # 清理锁文件
    cleanup_lock_files
}

# 显示后续步骤 (更新信息)
show_next_steps() {
    log_success "NVIDIA驱动安装完成！"
    echo
    echo -e "${GREEN}安装摘要:${NC}"
    echo "- 发行版: $DISTRO_ID $DISTRO_VERSION"
    echo "- 架构: $ARCH"
    echo "- 模块类型: $(if $USE_OPEN_MODULES; then echo "开源内核模块"; else echo "专有内核模块"; fi)"
    echo "- 安装类型: $INSTALL_TYPE"
    echo "- 仓库类型: $(if $USE_LOCAL_REPO; then echo "本地仓库"; else echo "网络仓库"; fi)"
    echo
    echo -e "${YELLOW}后续步骤:${NC}"
    echo "1. 重启系统以确保驱动完全生效"
    echo "2. 重启后运行 'nvidia-smi' 验证安装"
    echo "3. 如需安装CUDA Toolkit，请访问: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/"
    echo "4. 技术支持论坛: https://forums.developer.nvidia.com/c/gpu-graphics/linux/148"
    echo "5. 如遇问题，可运行 '$0 --rollback' 回滚安装"
    
    # Secure Boot相关提示
    if [[ -d /sys/firmware/efi/efivars ]] && [[ -f /sys/firmware/efi/efivars/SecureBoot-* ]]; then
        local sb_value=$(od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | tr -d ' ')
        if [[ "$sb_value" =~ 1$ ]]; then
            echo
            echo -e "${YELLOW}🔐 Secure Boot提醒：${NC}"
            echo "6. 重启时如果出现MOK Manager界面，请选择 'Enroll MOK' 并输入密码"
            echo "7. 如果驱动无法加载，检查: sudo dmesg | grep nvidia"
            echo "8. 验证模块签名: modinfo nvidia | grep sig"
        fi
    fi
    
    echo
    
    if [[ "$INSTALL_TYPE" == "compute-only" ]]; then
        echo -e "${BLUE}计算专用安装说明:${NC}"
        echo "- 此安装不包含桌面显卡组件 (OpenGL, Vulkan, X驱动等)"
        echo "- 适用于计算集群或无显示器的工作站"
        echo "- 如需添加桌面组件，可稍后安装相应包"
    elif [[ "$INSTALL_TYPE" == "desktop-only" ]]; then
        echo -e "${BLUE}桌面专用安装说明:${NC}"
        echo "- 此安装不包含CUDA计算组件"
        echo "- 适用于纯桌面/游戏用途"
        echo "- 如需CUDA支持，可稍后安装nvidia-driver-cuda包"
    fi
    
    if [[ "$USE_OPEN_MODULES" == "true" ]]; then
        echo -e "${BLUE}开源模块说明:${NC}"
        echo "- 使用MIT/GPLv2双重许可的开源内核模块"
        echo "- 支持Turing及更新架构 (RTX 16xx, 20xx, 30xx, 40xx系列)"
        echo "- 源代码: https://github.com/NVIDIA/open-gpu-kernel-modules"
    else
        echo -e "${BLUE}专有模块说明:${NC}"
        echo "- 使用NVIDIA传统专有内核模块"
        echo "- 兼容所有NVIDIA GPU架构"
        echo "- Maxwell、Pascal、Volta架构必须使用此模块"
    fi
}

# 检查是否以root权限运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        exit_with_code $EXIT_NO_ROOT "此脚本需要root权限运行，请使用: sudo $0"
    fi
}

# 主函数 (添加状态管理和无交互支持)
main() {
    # 检测终端环境，如果不是TTY则自动启用静默模式
    if [[ ! -t 0 ]] && [[ "$QUIET_MODE" != "true" ]]; then
        log_info "检测到非交互环境，启用静默模式"
        QUIET_MODE=true
    fi

    if ! [[ "$QUIET_MODE" == "true" ]]; then
        echo -e "${GREEN}"
        echo "=============================================="
        echo "  NVIDIA驱动官方安装脚本 v2.1"
        echo "  基于NVIDIA Driver Installation Guide r575"
        echo "  支持幂等操作和状态恢复"
        if [[ "$AUTO_YES" == "true" ]]; then
            echo "  无交互自动化模式"
        fi
        echo "=============================================="
        echo -e "${NC}"
    fi
    
    # 创建状态目录
    create_state_dir
    
    # 解析命令行参数
    parse_arguments "$@"
    
    # 检查root权限
    check_root
    
    # 检查上次安装状态
    local last_state=$(get_last_state)
    if [[ -n "$last_state" && "$last_state" != "installation_completed" ]]; then
        echo
        log_warning "检测到未完成的安装状态: $last_state"
        if ! [[ "$AUTO_YES" == "true" ]] && confirm "是否从上次中断处继续安装？" "N"; then
            log_info "从断点继续安装"
        else
            log_info "清理状态文件并重新开始"
            rm -f "$STATE_FILE" "$ROLLBACK_FILE"
        fi
    fi
    
    # 检测系统环境
    if ! is_step_completed "detect_distro"; then
        detect_distro
        save_state "detect_distro"
    fi
    
    if ! is_step_completed "check_distro_support"; then
        check_distro_support
        save_state "check_distro_support"
    fi
    
    if ! is_step_completed "check_nvidia_gpu"; then
        check_nvidia_gpu
        save_state "check_nvidia_gpu"
    fi
    
    if ! is_step_completed "check_existing_installation"; then
        check_existing_nvidia_installation
        save_state "check_existing_installation"
    fi
    
    if ! is_step_completed "pre_installation_checks"; then
        pre_installation_checks
        save_state "pre_installation_checks"
    fi
    
    # 显示安装配置
    if ! is_step_completed "show_config"; then
        echo
        echo -e "${PURPLE}安装配置:${NC}"
        echo "- 发行版: $DISTRO_ID $DISTRO_VERSION [$ARCH]"
        echo "- 模块类型: $(if $USE_OPEN_MODULES; then echo "开源内核模块"; else echo "专有内核模块"; fi)"
        echo "- 安装类型: $INSTALL_TYPE"
        echo "- 仓库类型: $(if $USE_LOCAL_REPO; then echo "本地仓库"; else echo "网络仓库"; fi)"
        echo "- 自动化模式: $(if $AUTO_YES; then echo "是"; else echo "否"; fi)"
        echo "- 强制重装: $(if $FORCE_REINSTALL; then echo "是"; else echo "否"; fi)"
        echo "- 自动重启: $(if $REBOOT_AFTER_INSTALL; then echo "是"; else echo "否"; fi)"
        echo

        if ! [[ "$AUTO_YES" == "true" ]] && ! [[ "$FORCE_REINSTALL" == "true" ]] && ! [[ "$SKIP_EXISTING_CHECKS" == "true" ]]; then
            if ! confirm "是否继续安装？" "Y"; then
                exit_with_code $EXIT_USER_CANCELLED "用户取消安装"
            fi
        fi
        save_state "show_config"
    fi
    
    # 开始安装过程
    echo
    log_info "开始NVIDIA驱动安装过程..."
    
    # 安装内核头文件
    install_kernel_headers
    
    # 启用仓库和依赖
    enable_repositories
    
    # 添加NVIDIA仓库
    add_nvidia_repository
    
    # 启用DNF模块 (如需要)
    if ! is_step_completed "enable_dnf_modules"; then
        enable_dnf_modules
        save_state "enable_dnf_modules"
    fi
    
    # 禁用nouveau驱动
    if ! is_step_completed "disable_nouveau"; then
        disable_nouveau
        save_state "disable_nouveau"
    fi
    
    # 安装NVIDIA驱动
    if ! is_step_completed "install_nvidia_driver"; then
        install_nvidia_driver
        save_state "install_nvidia_driver"
    fi
    
    # 启用persistence daemon
    if ! is_step_completed "enable_persistence_daemon"; then
        enable_persistence_daemon
        save_state "enable_persistence_daemon"
    fi
    
    # 验证安装
    if ! is_step_completed "verify_installation"; then
        verify_installation
        save_state "verify_installation"
    fi
    
    # 清理安装文件
    if ! is_step_completed "cleanup"; then
        cleanup
        save_state "cleanup"
    fi
    
    # 标记安装完成
    save_state "installation_completed"
    
    # 显示后续步骤
    show_next_steps
    
    echo
    if [ "$REBOOT_AFTER_INSTALL" = true ] || [ "$AUTO_YES" = true ]; then
        if [ "$REBOOT_AFTER_INSTALL" = true ]; then
            log_info "自动重启已启用，正在重启系统..."
        else
            log_info "自动化模式：建议重启系统以完成驱动安装"
            if confirm "是否现在重启系统？" "Y"; then
                log_info "正在重启系统..."
            else
                log_warning "请手动重启系统以完成驱动安装"
                log_info "安装完成后可运行 '$0 --cleanup' 清理状态文件"
                exit $EXIT_SUCCESS
            fi
        fi
        
        # 清理状态文件，因为安装已完成
        rm -f "$STATE_FILE" "$ROLLBACK_FILE"
        cleanup_lock_files
        reboot
    else
        if confirm "是否现在重启系统？" "N"; then
            log_info "正在重启系统..."
            # 清理状态文件，因为安装已完成
            rm -f "$STATE_FILE" "$ROLLBACK_FILE"
            cleanup_lock_files
            reboot
        else
            log_warning "请手动重启系统以完成驱动安装"
            log_info "安装完成后可运行 '$0 --cleanup' 清理状态文件"
            # 清理锁文件但保留状态文件
            cleanup_lock_files
        fi
    fi
}

# 运行主函数
main "$@"
