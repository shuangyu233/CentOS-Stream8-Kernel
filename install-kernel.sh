#!/bin/bash
#
# CentOS Stream 8 - ELRepo Kernel ML 一键下载安装脚本
# 仓库: https://github.com/shuangyu233/CentOS-Stream8-Kernel
#
# 用法:
#   本地执行:
#     ./install-kernel.sh              # 交互式选择版本
#     ./install-kernel.sh 6.18.10      # 指定版本号
#
#   远程一键执行:
#     curl -fsSL https://raw.githubusercontent.com/shuangyu233/CentOS-Stream8-Kernel/main/install-kernel.sh | sudo bash
#     curl -fsSL https://raw.githubusercontent.com/shuangyu233/CentOS-Stream8-Kernel/main/install-kernel.sh | sudo bash -s 6.18.10
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
RPM_DIR=""
SELECTED_VERSION=""

# ELRepo GPG Key ID
ELREPO_KEY_ID="baadae52"
ELREPO_KEY_URL="https://www.elrepo.org/RPM-GPG-KEY-elrepo.org"

# curl 超时设置（秒）
CURL_CONNECT_TIMEOUT=15
CURL_MAX_TIME=600
CURL_RETRY=3

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
# 仅在终端输出时使用颜色
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
fi

# ==================== 工具函数 ====================
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()    { echo -e "${CYAN}[STEP]${NC} $*"; }

# 关键修复：curl | bash 时 stdin 被管道占用，所有交互式读取必须从 /dev/tty 读取
prompt_read() {
    local prompt="$1"
    local varname="$2"
    local input=""

    if [[ -t 0 ]]; then
        # stdin 是终端，直接读取
        read -rp "$prompt" input
    elif [[ -e /dev/tty ]]; then
        # stdin 被管道占用（curl | bash），从 /dev/tty 读取
        read -rp "$prompt" input < /dev/tty
    else
        # 无可用终端，返回空值
        input=""
    fi

    printf -v "$varname" '%s' "$input"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要 root 权限运行"
        error "请使用: sudo bash $0 $*"
        error "或: curl -fsSL <URL> | sudo bash"
        exit 1
    fi
}

check_system() {
    if [[ ! -f /etc/redhat-release ]]; then
        error "此脚本仅适用于 CentOS/RHEL 系统"
        exit 1
    fi

    local release
    release=$(cat /etc/redhat-release)
    if ! echo "$release" | grep -qiE '(centos|red hat).*(stream )?8'; then
        warn "当前系统: $release"
        warn "此脚本设计用于 CentOS Stream 8，其他版本可能不兼容"
        local confirm=""
        prompt_read "是否继续？(y/N): " confirm
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

check_disk_space() {
    # 需要约 300MB 临时空间 + 安装空间
    local tmp_avail
    tmp_avail=$(df -BM /tmp 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'M')
    if [[ -n "$tmp_avail" && "$tmp_avail" -lt 500 ]]; then
        warn "/tmp 可用空间不足 500MB（当前: ${tmp_avail}MB），下载可能失败"
    fi
}

# ==================== GPG 密钥管理 ====================
import_elrepo_key() {
    # 检查是否已导入 ELRepo GPG 密钥
    if rpm -qa gpg-pubkey* 2>/dev/null | grep -qi "${ELREPO_KEY_ID}"; then
        info "ELRepo GPG 密钥已导入"
        return 0
    fi

    step "导入 ELRepo GPG 密钥..."
    if rpm --import "${ELREPO_KEY_URL}" 2>/dev/null; then
        info "ELRepo GPG 密钥导入成功"
    else
        warn "ELRepo GPG 密钥导入失败，将跳过签名验证"
    fi
}

# ==================== 获取可用版本 ====================
get_local_versions() {
    # 在 curl | bash 模式下 BASH_SOURCE[0] 可能为空
    local script_dir=""
    if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" && "${BASH_SOURCE[0]}" != "-bash" ]]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi

    if [[ -z "$script_dir" ]]; then
        return 0
    fi

    local elrepo_path="${script_dir}/${ELREPO_DIR}"
    if [[ -d "$elrepo_path" ]]; then
        find "$elrepo_path" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort -V
    fi
}

get_remote_versions() {
    local response
    response=$(curl -sL \
        --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
        --max-time 30 \
        --retry "${CURL_RETRY}" \
        "${GITHUB_API}/contents/${ELREPO_DIR}?ref=${REPO_BRANCH}" 2>/dev/null) || return 1

    # 检查 API 限流
    if echo "$response" | grep -q '"message".*rate limit'; then
        error "GitHub API 请求频率超限，请稍后重试"
        return 1
    fi

    echo "$response" \
        | grep '"name"' \
        | sed 's/.*"name": "\(.*\)".*/\1/' \
        | grep -E '^[0-9]+\.' \
        | sort -V
}

get_versions() {
    local versions=""

    # 优先使用本地目录
    versions=$(get_local_versions)
    if [[ -n "$versions" ]]; then
        echo "$versions"
        return 0
    fi

    # 从 GitHub API 获取
    step "从 GitHub 获取可用版本列表..." >&2
    versions=$(get_remote_versions) || true
    if [[ -n "$versions" ]]; then
        echo "$versions"
        return 0
    fi

    error "无法获取可用版本列表"
    error "请检查网络连接，或直接指定版本号运行"
    return 1
}

# ==================== 版本选择 ====================
select_version() {
    local versions_str
    versions_str=$(get_versions) || exit 1

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

    local choice=""
    prompt_read "请选择版本 [1-${#versions[@]}]: " choice

    # 输入为空时（无终端），默认选最新版本
    if [[ -z "$choice" ]]; then
        choice="${#versions[@]}"
        warn "无法读取输入，自动选择最新版本"
    fi

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

    # 检查本地是否已有文件（仅在非管道模式下）
    local script_dir=""
    if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" && "${BASH_SOURCE[0]}" != "-bash" ]]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi

    if [[ -n "$script_dir" ]]; then
        local local_path="${script_dir}/${ELREPO_DIR}/${version}"
        if [[ -d "$local_path" ]] && ls "$local_path"/*.rpm &>/dev/null; then
            info "使用本地 RPM 包: ${local_path}"
            RPM_DIR="$local_path"
            return 0
        fi
    fi

    # 从 GitHub 下载
    step "从 GitHub 下载 RPM 包..."
    mkdir -p "${TMP_DIR}/${version}"
    RPM_DIR="${TMP_DIR}/${version}"

    # 获取文件列表
    local response
    response=$(curl -sL \
        --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
        --max-time 30 \
        --retry "${CURL_RETRY}" \
        "${GITHUB_API}/contents/${ELREPO_DIR}/${version}?ref=${REPO_BRANCH}" 2>/dev/null) || {
        error "无法连接到 GitHub，请检查网络"
        exit 1
    }

    local files
    files=$(echo "$response" \
        | grep '"download_url"' \
        | sed 's/.*"download_url": "\(.*\)".*/\1/' \
        | grep '\.rpm$')

    if [[ -z "$files" ]]; then
        error "无法获取版本 ${version} 的文件列表，请确认版本号是否正确"
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
        if ! curl -L --progress-bar \
                --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
                --max-time "${CURL_MAX_TIME}" \
                --retry "${CURL_RETRY}" \
                -o "${RPM_DIR}/${filename}" "$url"; then
            error "下载失败: ${filename}"
            error "请检查网络连接后重试"
            exit 1
        fi

        # 简单校验：文件大小不为 0
        if [[ ! -s "${RPM_DIR}/${filename}" ]]; then
            error "下载的文件为空: ${filename}"
            exit 1
        fi
    done <<< "$files"

    info "所有 RPM 包下载完成 (共 ${total} 个)"

    # 下载 SHA256SUMS 校验文件
    local sha256_url="${GITHUB_RAW}/${ELREPO_DIR}/${version}/SHA256SUMS"
    echo -e "  下载 SHA256SUMS..."
    if curl -sL \
            --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
            --max-time 30 \
            --retry "${CURL_RETRY}" \
            -o "${RPM_DIR}/SHA256SUMS" "$sha256_url" 2>/dev/null \
       && [[ -s "${RPM_DIR}/SHA256SUMS" ]]; then
        info "SHA256SUMS 校验文件已下载"
    else
        warn "SHA256SUMS 校验文件下载失败，将跳过 SHA256 校验"
        rm -f "${RPM_DIR}/SHA256SUMS"
    fi
}

# ==================== 校验 RPM 包 ====================
verify_rpms() {
    local rpm_dir="$1"

    # ---- 第一步：SHA256 文件完整性校验 ----
    local sha256_file="${rpm_dir}/SHA256SUMS"
    if [[ -f "$sha256_file" ]]; then
        step "SHA256 完整性校验..."
        local sha256_failed=0
        local sha256_checked=0

        pushd "$rpm_dir" > /dev/null
        while IFS= read -r line; do
            # 跳过空行和注释
            [[ -z "$line" || "$line" == \#* ]] && continue

            local expected_hash file_name
            expected_hash=$(echo "$line" | awk '{print $1}')
            file_name=$(echo "$line" | awk '{print $2}')

            if [[ ! -f "$file_name" ]]; then
                echo -e "  ${RED}✗${NC} ${file_name} (文件不存在)"
                ((sha256_failed++))
                continue
            fi

            local actual_hash
            actual_hash=$(sha256sum "$file_name" | awk '{print $1}')
            ((sha256_checked++))

            if [[ "$actual_hash" == "$expected_hash" ]]; then
                echo -e "  ${GREEN}✓${NC} ${file_name} (SHA256)"
            else
                echo -e "  ${RED}✗${NC} ${file_name} (SHA256 不匹配)"
                echo -e "    预期: ${expected_hash}"
                echo -e "    实际: ${actual_hash}"
                ((sha256_failed++))
            fi
        done < "$sha256_file"
        popd > /dev/null

        if [[ $sha256_failed -gt 0 ]]; then
            error "${sha256_failed} 个文件 SHA256 校验失败，中止安装"
            error "文件可能已损坏或被篡改，请重新下载"
            exit 1
        fi

        if [[ $sha256_checked -gt 0 ]]; then
            info "SHA256 校验通过 (${sha256_checked} 个文件)"
        fi
    else
        warn "未找到 SHA256SUMS 校验文件，跳过 SHA256 校验"
    fi

    echo ""

    # ---- 第二步：RPM 内部摘要 + 签名校验 ----
    step "RPM 包签名与摘要校验..."

    local failed=0
    local total=0
    for rpm_file in "$rpm_dir"/*.rpm; do
        [[ -f "$rpm_file" ]] || continue
        ((total++))
        local basename_file
        basename_file=$(basename "$rpm_file")

        # 首先验证摘要（完整性）
        if rpm -K --nosignature "$rpm_file" &>/dev/null; then
            # 尝试签名验证
            if rpm -K "$rpm_file" &>/dev/null; then
                echo -e "  ${GREEN}✓${NC} ${basename_file} (签名+摘要)"
            else
                echo -e "  ${GREEN}✓${NC} ${basename_file} (摘要通过，签名未验证)"
            fi
        else
            echo -e "  ${RED}✗${NC} ${basename_file} (RPM 摘要校验失败)"
            ((failed++))
        fi
    done

    if [[ $total -eq 0 ]]; then
        error "目录中没有找到 RPM 包"
        exit 1
    fi

    if [[ $failed -gt 0 ]]; then
        error "${failed}/${total} 个包 RPM 校验失败，中止安装"
        error "包文件可能已损坏，请重新下载"
        exit 1
    fi

    info "所有 RPM 包校验通过 (${total} 个)"
}

# ==================== 安装 RPM 包 ====================
install_rpms() {
    local rpm_dir="$1"
    local version="$2"

    step "准备安装 kernel-ml-${version}..."
    echo ""

    # 检查是否已安装相同版本
    if rpm -q "kernel-ml-core-${version}-1.el8.elrepo" &>/dev/null; then
        warn "kernel-ml-${version} 已经安装"
        local confirm=""
        prompt_read "是否重新安装？(y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "取消安装"
            exit 0
        fi
    fi

    # 按依赖顺序构建安装列表
    local ordered_rpms=()
    local skipped=()
    for pkg in "${INSTALL_ORDER[@]}"; do
        local rpm_file
        rpm_file=$(find "$rpm_dir" -name "${pkg}-${version}*.rpm" -type f 2>/dev/null | head -1)
        if [[ -n "$rpm_file" ]]; then
            ordered_rpms+=("$rpm_file")
        else
            skipped+=("$pkg")
        fi
    done

    if [[ ${#ordered_rpms[@]} -eq 0 ]]; then
        error "没有找到可安装的 RPM 包"
        exit 1
    fi

    # 检查核心包是否存在
    local has_core=false
    for rpm_file in "${ordered_rpms[@]}"; do
        if basename "$rpm_file" | grep -q "kernel-ml-core"; then
            has_core=true
            break
        fi
    done

    if ! $has_core; then
        error "缺少核心包 kernel-ml-core，无法继续安装"
        exit 1
    fi

    if [[ ${#skipped[@]} -gt 0 ]]; then
        warn "以下包未找到，将跳过: ${skipped[*]}"
    fi

    echo "将按以下顺序安装:"
    echo ""
    local i=1
    for rpm_file in "${ordered_rpms[@]}"; do
        echo -e "  ${CYAN}${i}.${NC} $(basename "$rpm_file")"
        ((i++))
    done
    echo ""

    local confirm=""
    prompt_read "确认安装？(Y/n): " confirm
    # 空值（包括管道模式无终端）默认为 Yes
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "取消安装"
        exit 0
    fi

    # 使用 dnf 或 yum 安装（一次性传入所有包，由包管理器处理依赖顺序）
    echo ""
    if command -v dnf &>/dev/null; then
        step "使用 dnf 安装（自动处理依赖）..."
        if ! dnf install -y "${ordered_rpms[@]}"; then
            error "dnf 安装失败"
            exit 1
        fi
    elif command -v yum &>/dev/null; then
        step "使用 yum 安装（自动处理依赖）..."
        if ! yum localinstall -y "${ordered_rpms[@]}"; then
            error "yum 安装失败"
            exit 1
        fi
    else
        step "使用 rpm 按顺序安装..."
        for rpm_file in "${ordered_rpms[@]}"; do
            local basename_file
            basename_file=$(basename "$rpm_file")
            echo -e "  安装 ${basename_file}..."
            if ! rpm -ivh "$rpm_file"; then
                error "安装失败: ${basename_file}"
                error "尝试: rpm -ivh --nodeps ${basename_file}"
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
        grubby --info=ALL 2>/dev/null | grep -E "^(index|kernel|title)" | head -20 || true
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
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

# ==================== 主流程 ====================
main() {
    check_root "$@"
    check_system
    check_dependencies
    check_disk_space
    import_elrepo_key

    local version="${1:-}"

    if [[ -n "$version" ]]; then
        # 命令行指定版本号：校验格式
        if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            error "版本号格式无效: $version"
            error "示例: 6.18.10"
            exit 1
        fi
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
