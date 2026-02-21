#!/bin/bash
#
# CentOS Stream 8 - ELRepo Kernel ML 一键下载安装脚本
# 仓库: https://github.com/shuangyu233/CentOS-Stream8-Kernel
#
# 用法:
#   ./install-kernel.sh              # 交互式选择版本
#   ./install-kernel.sh 6.18.10      # 指定版本号
#

set -euo pipefail

# ==================== 配置 ====================
REPO_OWNER="shuangyu233"
REPO_NAME="CentOS-Stream8-Kernel"
REPO_BRANCH="main"
GITHUB_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"
GITHUB_API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"
ELREPO_DIR="elrepo"
TMP_DIR="/tmp/kernel-ml-install"

# RPM 包安装顺序（按依赖关系排列）
INSTALL_ORDER=(
    "kernel-ml-headers"
    "kernel-ml-core"
    "kernel-ml-modules"
    "kernel-ml-modules-extra"
    "kernel-ml-devel"
    "kernel-ml"
)

# ==================== 颜色定义 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ==================== 工具函数 ====================
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
step()    { echo -e "${CYAN}[STEP]${NC} $*"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要 root 权限运行"
        echo "请使用: sudo $0 $*"
        exit 1
    fi
}

check_system() {
    # 检查是否为 CentOS/RHEL 8
    if [[ ! -f /etc/redhat-release ]]; then
        error "此脚本仅适用于 CentOS/RHEL 系统"
        exit 1
    fi

    local release
    release=$(cat /etc/redhat-release)
    if ! echo "$release" | grep -qiE '(centos|red hat).*(stream )?8'; then
        warn "当前系统: $release"
        warn "此脚本设计用于 CentOS Stream 8，其他版本可能不兼容"
        read -rp "是否继续？(y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
    fi

    info "系统检查通过: $release"
}

check_dependencies() {
    local missing=()
    for cmd in curl rpm; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "缺少必要的工具: ${missing[*]}"
        exit 1
    fi
}

# ==================== 获取可用版本 ====================
get_local_versions() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local elrepo_path="${script_dir}/${ELREPO_DIR}"

    if [[ -d "$elrepo_path" ]]; then
        find "$elrepo_path" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort -V
    fi
}

get_remote_versions() {
    curl -sL "${GITHUB_API}/contents/${ELREPO_DIR}?ref=${REPO_BRANCH}" 2>/dev/null \
        | grep '"name"' \
        | sed 's/.*"name": "\(.*\)".*/\1/' \
        | sort -V
}

get_versions() {
    local versions

    # 优先使用本地目录
    versions=$(get_local_versions)
    if [[ -n "$versions" ]]; then
        echo "$versions"
        return 0
    fi

    # 尝试从 GitHub API 获取
    versions=$(get_remote_versions)
    if [[ -n "$versions" ]]; then
        echo "$versions"
        return 0
    fi

    return 1
}

# ==================== 版本选择 ====================
select_version() {
    local versions_str
    versions_str=$(get_versions) || {
        error "无法获取可用版本列表"
        exit 1
    }

    local versions=()
    while IFS= read -r v; do
        [[ -n "$v" ]] && versions+=("$v")
    done <<< "$versions_str"

    if [[ ${#versions[@]} -eq 0 ]]; then
        error "没有找到可用的内核版本"
        exit 1
    fi

    echo ""
    echo -e "${BLUE}===========================================${NC}"
    echo -e "${BLUE}   CentOS Stream 8 - Kernel ML 安装工具    ${NC}"
    echo -e "${BLUE}===========================================${NC}"
    echo ""
    echo -e "当前系统内核: ${CYAN}$(uname -r)${NC}"
    echo ""
    echo "可用的内核版本:"
    echo ""

    local i=1
    for v in "${versions[@]}"; do
        echo -e "  ${GREEN}${i})${NC} kernel-ml-${v}"
        ((i++))
    done
    echo ""

    local choice
    read -rp "请选择版本 [1-${#versions[@]}]: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#versions[@]} ]]; then
        error "无效的选择: $choice"
        exit 1
    fi

    SELECTED_VERSION="${versions[$((choice - 1))]}"
    info "已选择版本: kernel-ml-${SELECTED_VERSION}"
}

# ==================== 下载/定位 RPM 包 ====================
prepare_rpms() {
    local version="$1"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local local_path="${script_dir}/${ELREPO_DIR}/${version}"

    # 检查本地是否已有文件
    if [[ -d "$local_path" ]] && ls "$local_path"/*.rpm &>/dev/null; then
        info "使用本地 RPM 包: ${local_path}"
        RPM_DIR="$local_path"
        return 0
    fi

    # 从 GitHub 下载
    step "从 GitHub 下载 RPM 包..."
    mkdir -p "${TMP_DIR}/${version}"
    RPM_DIR="${TMP_DIR}/${version}"

    # 获取文件列表
    local files
    files=$(curl -sL "${GITHUB_API}/contents/${ELREPO_DIR}/${version}?ref=${REPO_BRANCH}" 2>/dev/null \
        | grep '"download_url"' \
        | sed 's/.*"download_url": "\(.*\)".*/\1/' \
        | grep '\.rpm$')

    if [[ -z "$files" ]]; then
        error "无法获取版本 ${version} 的文件列表"
        exit 1
    fi

    local total
    total=$(echo "$files" | wc -l)
    local count=0

    while IFS= read -r url; do
        ((count++))
        local filename
        filename=$(basename "$url")
        echo -e "  [${count}/${total}] 下载 ${filename}..."
        if ! curl -L --progress-bar -o "${RPM_DIR}/${filename}" "$url"; then
            error "下载失败: ${filename}"
            exit 1
        fi
    done <<< "$files"

    info "所有 RPM 包下载完成"
}

# ==================== 校验 RPM 包 ====================
verify_rpms() {
    local rpm_dir="$1"

    step "校验 RPM 包完整性..."

    local failed=0
    for rpm_file in "$rpm_dir"/*.rpm; do
        local basename_file
        basename_file=$(basename "$rpm_file")
        if rpm -K --nosignature "$rpm_file" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} ${basename_file}"
        else
            echo -e "  ${RED}✗${NC} ${basename_file}"
            ((failed++))
        fi
    done

    if [[ $failed -gt 0 ]]; then
        error "${failed} 个包校验失败，中止安装"
        exit 1
    fi

    info "所有 RPM 包校验通过"
}

# ==================== 安装 RPM 包 ====================
install_rpms() {
    local rpm_dir="$1"
    local version="$2"

    step "准备安装 kernel-ml-${version}..."
    echo ""

    # 检查是否已安装相同版本
    if rpm -q "kernel-ml-core-${version}" &>/dev/null; then
        warn "kernel-ml-${version} 已经安装"
        read -rp "是否重新安装？(y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "取消安装"
            exit 0
        fi
    fi

    # 按依赖顺序构建安装列表
    local ordered_rpms=()
    for pkg in "${INSTALL_ORDER[@]}"; do
        local rpm_file
        rpm_file=$(find "$rpm_dir" -name "${pkg}-${version}*.rpm" -type f 2>/dev/null | head -1)
        if [[ -n "$rpm_file" ]]; then
            ordered_rpms+=("$rpm_file")
        else
            warn "未找到包: ${pkg}，跳过"
        fi
    done

    if [[ ${#ordered_rpms[@]} -eq 0 ]]; then
        error "没有找到可安装的 RPM 包"
        exit 1
    fi

    echo "将按以下顺序安装:"
    echo ""
    local i=1
    for rpm_file in "${ordered_rpms[@]}"; do
        echo -e "  ${CYAN}${i}.${NC} $(basename "$rpm_file")"
        ((i++))
    done
    echo ""

    read -rp "确认安装？(Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "取消安装"
        exit 0
    fi

    # 使用 dnf 或 rpm 安装
    echo ""
    if command -v dnf &>/dev/null; then
        step "使用 dnf 安装（自动处理依赖）..."
        dnf install -y "${ordered_rpms[@]}"
    elif command -v yum &>/dev/null; then
        step "使用 yum 安装（自动处理依赖）..."
        yum localinstall -y "${ordered_rpms[@]}"
    else
        step "使用 rpm 按顺序安装..."
        for rpm_file in "${ordered_rpms[@]}"; do
            local basename_file
            basename_file=$(basename "$rpm_file")
            echo -e "  安装 ${basename_file}..."
            if ! rpm -ivh --nodeps "$rpm_file"; then
                error "安装失败: ${basename_file}"
                exit 1
            fi
        done
    fi

    echo ""
    info "kernel-ml-${version} 安装完成！"
}

# ==================== 安装后信息 ====================
post_install() {
    local version="$1"

    echo ""
    echo -e "${BLUE}===========================================${NC}"
    echo -e "${BLUE}              安装完成                      ${NC}"
    echo -e "${BLUE}===========================================${NC}"
    echo ""
    echo -e "当前内核:   ${YELLOW}$(uname -r)${NC}"
    echo -e "已安装内核: ${GREEN}kernel-ml-${version}${NC}"
    echo ""

    # 显示 grub 中的内核列表
    if command -v grubby &>/dev/null; then
        step "已安装的内核列表:"
        grubby --info=ALL 2>/dev/null | grep -E "^(index|kernel|title)" | head -20
        echo ""

        # 显示默认启动内核
        local default_kernel
        default_kernel=$(grubby --default-kernel 2>/dev/null || true)
        if [[ -n "$default_kernel" ]]; then
            echo -e "默认启动内核: ${CYAN}${default_kernel}${NC}"
        fi
    fi

    echo ""
    echo -e "${YELLOW}请重启系统以使用新内核: sudo reboot${NC}"
    echo ""
}

# ==================== 清理临时文件 ====================
cleanup() {
    if [[ -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

# ==================== 主流程 ====================
main() {
    check_root "$@"
    check_system
    check_dependencies

    local version="${1:-}"

    if [[ -n "$version" ]]; then
        # 命令行指定版本号
        SELECTED_VERSION="$version"
        info "指定版本: kernel-ml-${SELECTED_VERSION}"
    else
        # 交互式选择
        select_version
    fi

    prepare_rpms "$SELECTED_VERSION"
    verify_rpms "$RPM_DIR"
    install_rpms "$RPM_DIR" "$SELECTED_VERSION"
    post_install "$SELECTED_VERSION"

    # 清理下载的临时文件
    cleanup
}

trap cleanup EXIT
main "$@"
