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

set -uo pipefail

# ==================== 配置 ====================
REPO_OWNER="shuangyu233"
REPO_NAME="CentOS-Stream8-Kernel"
REPO_BRANCH="main"
GITHUB_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"
GITHUB_API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"
KERNEL_TRACKS=("ML" "LTS" "Test")
SELECTED_TRACK="ML"
TMP_DIR_BASE="/tmp/kernel-ml-install"
TMP_DIR=""
TMP_CREATED=0
RPM_DIR=""
SELECTED_VERSION=""
DRY_RUN=0

# ELRepo GPG Key IDs（兼容旧/新签名密钥）
ELREPO_KEY_IDS_REGEX="(baadae52|eaa31d4a)"
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
die()     { error "$@"; exit 1; }

# 获取脚本所在目录（管道执行时返回空字符串）
get_script_dir() {
    if [[ -n "${BASH_SOURCE[0]:-}" \
       && "${BASH_SOURCE[0]}" != "bash" \
       && "${BASH_SOURCE[0]}" != "-bash" ]]; then
        # 用子 shell 避免改变当前进程的工作目录
        ( cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd ) || true
    fi
}

create_tmp_dir() {
    if [[ "${TMP_CREATED:-0}" -eq 1 ]] && [[ -n "${TMP_DIR:-}" ]] && [[ -d "${TMP_DIR}" ]]; then
        return 0
    fi

    TMP_DIR=$(mktemp -d "${TMP_DIR_BASE}.XXXXXX") || die "创建临时目录失败"
    TMP_CREATED=1
}

# prompt_read: 将提示符写到终端，从终端读取一行输入，结果输出到 stdout
# 用法: var=$(prompt_read "提示")
# curl | bash 时 stdin 是管道，必须从 /dev/tty 读取用户输入；提示符写到 /dev/tty 避免被 $() 吃掉
prompt_read() {
    local __prompt__="$1"
    local __buf__=""

    if [[ -t 0 ]]; then
        # 正常终端模式
        read -rp "$__prompt__" __buf__
    elif [[ -e /dev/tty ]]; then
        # 管道模式（curl | bash）：提示符送到 /dev/tty，从 /dev/tty 读输入
        printf '%s' "$__prompt__" >/dev/tty
        IFS= read -r __buf__ </dev/tty
    fi
    # 将结果输出到 stdout，由调用方用 $() 捕获
    printf '%s' "$__buf__"
}

prompt_yes_no() {
    local __prompt__="$1"
    local __default__="$2"
    local __varname__="$3"
    local __input__

    while true; do
        __input__=$(prompt_read "$__prompt__")
        case "$__input__" in
            "")
                printf -v "$__varname__" '%s' "$__default__"
                return 0
                ;;
            [Yy]|[Yy][Ee][Ss])
                printf -v "$__varname__" '%s' "y"
                return 0
                ;;
            [Nn]|[Nn][Oo])
                printf -v "$__varname__" '%s' "n"
                return 0
                ;;
            *)
                warn "输入无效，请输入 y 或 n（或直接回车使用默认值）"
                ;;
        esac
    done
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要 root 权限运行"
        error "请使用: sudo bash $0"
        error "或: curl -fsSL <URL> | sudo bash"
        exit 1
    fi
}

check_system() {
    if [[ ! -f /etc/redhat-release ]]; then
        die "此脚本仅适用于 CentOS/RHEL 系统"
    fi

    local release
    release=$(cat /etc/redhat-release)
    if ! echo "$release" | grep -qiE '(centos|red hat).*(stream )?8'; then
        warn "当前系统: $release"
        warn "此脚本设计用于 CentOS Stream 8，其他版本可能不兼容"
        local confirm
        prompt_yes_no "是否继续？(y/N): " "n" confirm
        [[ "$confirm" == "y" ]] || exit 0
    fi

    info "系统检查通过: $release"
}

check_dependencies() {
    local missing=()
    for cmd in curl rpm awk grep sed sha256sum find df mktemp; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "缺少必要的工具: ${missing[*]}"
    fi
}

check_disk_space() {
    local tmp_avail
    tmp_avail=$(df -m /tmp 2>/dev/null | awk 'NR==2{print $4}' || echo "")
    if [[ -n "$tmp_avail" ]] && [[ "$tmp_avail" =~ ^[0-9]+$ ]] && [[ "$tmp_avail" -lt 500 ]]; then
        warn "/tmp 可用空间不足 500MB（当前: ${tmp_avail}MB），下载可能失败"
    fi

    local boot_avail
    boot_avail=$(df -m /boot 2>/dev/null | awk 'NR==2{print $4}' || echo "")
    if [[ -n "$boot_avail" ]] && [[ "$boot_avail" =~ ^[0-9]+$ ]] && [[ "$boot_avail" -lt 300 ]]; then
        warn "/boot 可用空间不足 300MB（当前: ${boot_avail}MB），内核安装可能失败"
    fi
}

# ==================== GPG 密钥管理 ====================
import_elrepo_key() {
    if rpm -qa gpg-pubkey* 2>/dev/null | grep -Eqi "${ELREPO_KEY_IDS_REGEX}" 2>/dev/null; then
        info "ELRepo GPG 密钥已导入"
        return 0
    fi

    step "导入 ELRepo GPG 密钥..."
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        info "[DRY-RUN] 模拟导入 ELRepo GPG 密钥: ${ELREPO_KEY_URL}"
        return 0
    fi

    if rpm --import "${ELREPO_KEY_URL}" 2>/dev/null; then
        info "ELRepo GPG 密钥导入成功"
    else
        warn "ELRepo GPG 密钥导入失败，将跳过签名验证"
    fi
}

# ==================== 获取可用版本 ====================
get_local_versions() {
    local script_dir
    script_dir=$(get_script_dir)
    [[ -z "$script_dir" ]] && return 0

    local track output=""
    for track in "${KERNEL_TRACKS[@]}"; do
        local track_path="${script_dir}/${track}"
        if [[ -d "$track_path" ]]; then
            while IFS= read -r v; do
                [[ -n "$v" ]] && output+="${track}|${v}"$'\n'
            done < <(find "$track_path" -mindepth 1 -maxdepth 1 -type d \
                         -exec basename {} \; 2>/dev/null | sort -V || true)
        fi
    done
    [[ -n "$output" ]] && printf '%s' "$output"
}

# 获取单个轨道的远程版本列表，输出 "track|version" 行
_fetch_track_versions() {
    local track="$1"
    local response
    response=$(curl -fsSL \
        --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
        --max-time 30 \
        --retry "${CURL_RETRY}" \
        "${GITHUB_API}/contents/${track}?ref=${REPO_BRANCH}" 2>/dev/null) || return 1

    if echo "$response" | grep -q '"message".*rate limit' 2>/dev/null; then
        error "GitHub API 请求频率超限，请稍后重试"
        return 1
    fi

    local versions
    versions=$(echo "$response" \
        | grep '"name"' 2>/dev/null \
        | sed 's/.*"name": "\(.*\)".*/\1/' 2>/dev/null \
        | grep -E '^[0-9]+\.' 2>/dev/null \
        | sort -V 2>/dev/null) || true

    if [[ -n "$versions" ]]; then
        while IFS= read -r v; do
            [[ -n "$v" ]] && echo "${track}|${v}"
        done <<< "$versions"
    fi
}

get_remote_versions() {
    local track found=false
    for track in "${KERNEL_TRACKS[@]}"; do
        local track_result
        track_result=$(_fetch_track_versions "$track") || true
        if [[ -n "$track_result" ]]; then
            echo "$track_result"
            found=true
        fi
    done
    if ! $found; then
        error "从 GitHub 获取版本列表返回为空"
        return 1
    fi
}

get_versions() {
    local versions=""

    # 优先使用本地目录
    versions=$(get_local_versions) || true
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
    versions_str=$(get_versions) || die "获取版本列表失败"

    # 解析 "track|version" 条目
    local track_versions=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && track_versions+=("$line")
    done <<< "$versions_str"

    if [[ ${#track_versions[@]} -eq 0 ]]; then
        die "没有找到可用的内核版本"
    fi

    # 预取已安装的 kernel-ml-core 版本（可能多个）
    local installed_versions
    installed_versions=$(rpm -q --qf '%{VERSION}\n' kernel-ml-core 2>/dev/null | sort -u || true)

    # 当前运行内核：仅取 X.Y.Z 部分
    local running_full running_version
    running_full=$(uname -r)
    running_version="${running_full%%-*}"

    echo ""
    echo -e "${BLUE}===========================================${NC}"
    echo -e "${BLUE}   CentOS Stream 8 - Kernel ML 安装工具    ${NC}"
    echo -e "${BLUE}===========================================${NC}"
    echo ""
    echo -e "当前系统内核: ${CYAN}${running_full}${NC}"
    echo ""
    echo "可用的内核版本:"
    echo ""

    local i=1
    for tv in "${track_versions[@]}"; do
        local track="${tv%%|*}"
        local version="${tv##*|}"

        # 轨道标签与颜色
        local badge badge_color
        case "$track" in
            ML)     badge="[ML  ]"; badge_color="${CYAN}"   ;;
            LTS)    badge="[LTS ]"; badge_color="${YELLOW}" ;;
            Test)   badge="[Test]"; badge_color="${RED}"    ;;
            *)      badge="[?   ]"; badge_color="${NC}"     ;;
        esac

        # 已安装标记
        local status_str=""
        if echo "$installed_versions" | grep -qx "$version" 2>/dev/null; then
            status_str="  ${GREEN}✓ 已安装${NC}"
        fi

        # 当前运行标记
        local running_str=""
        if [[ "$version" == "$running_version" ]]; then
            running_str="  ${BLUE}← 当前运行${NC}"
        fi

        echo -e "  ${GREEN}${i})${NC}  ${badge_color}${badge}${NC}  kernel-ml-${version}${status_str}${running_str}"
        i=$((i + 1))
    done
    echo ""

    # 轨道说明
    echo -e "  ${CYAN}[ML  ]${NC} MainLine — ELRepo 主线内核（最新特性）"
    echo -e "  ${YELLOW}[LTS ]${NC} LTS      — 长期支持内核（稳定优先）"
    echo -e "  ${RED}[Test]${NC} Test     — 测试版本（请勿用于生产环境）"
    echo ""

    # 重试循环：输入无效时重新提示（最多 5 次）
    local max_attempts=5
    local attempt=0
    while true; do
        attempt=$((attempt + 1))
        if [[ $attempt -gt $max_attempts ]]; then
            die "输入错误次数过多，退出"
        fi

        local choice
        choice=$(prompt_read "请选择版本 [1-${#track_versions[@]}]: ")

        # 无终端输入时默认选最新版本
        if [[ -z "$choice" ]]; then
            choice="${#track_versions[@]}"
            warn "无法读取输入，自动选择最新版本"
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#track_versions[@]} ]]; then
            local selected="${track_versions[$((choice - 1))]}"
            SELECTED_TRACK="${selected%%|*}"
            SELECTED_VERSION="${selected##*|}"
            local track_label
            case "$SELECTED_TRACK" in
                ML)   track_label="MainLine(ML)" ;;
                LTS)  track_label="LTS"          ;;
                Test) track_label="Test"         ;;
                *)    track_label="$SELECTED_TRACK" ;;
            esac
            info "已选择: [${track_label}] kernel-ml-${SELECTED_VERSION}"
            return 0
        fi

        warn "无效的选择: ${choice}，请输入 1 到 ${#track_versions[@]} 之间的数字"
    done
}

# ==================== 下载/定位 RPM 包 ====================
prepare_rpms() {
    local version="$1"

    # 优先使用本地文件（仅在非管道模式下有效）
    local script_dir
    script_dir=$(get_script_dir)
    if [[ -n "$script_dir" ]]; then
        local local_path="${script_dir}/${SELECTED_TRACK}/${version}"
        if [[ -d "$local_path" ]] && ls "$local_path"/*.rpm &>/dev/null; then
            info "使用本地 RPM 包: ${local_path}"
            RPM_DIR="$local_path"
            return 0
        fi
    fi

    # 从 GitHub 下载
    step "从 GitHub 下载 RPM 包..."
    create_tmp_dir
    mkdir -p "${TMP_DIR}/${version}"
    RPM_DIR="${TMP_DIR}/${version}"

    # 获取文件列表
    local response=""
    response=$(curl -fsSL \
        --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
        --max-time 30 \
        --retry "${CURL_RETRY}" \
        "${GITHUB_API}/contents/${SELECTED_TRACK}/${version}?ref=${REPO_BRANCH}" 2>/dev/null) || {
        die "无法连接到 GitHub，请检查网络"
    }

    if [[ -z "$response" ]]; then
        die "GitHub API 返回为空，请检查网络连接"
    fi

    # 提取 RPM 文件的下载 URL（防止 grep 无匹配导致管道失败）
    local files=""
    files=$(echo "$response" \
        | grep -v '"download_url": null' 2>/dev/null \
        | grep '"download_url"' 2>/dev/null \
        | sed 's/.*"download_url": "\(.*\)".*/\1/' 2>/dev/null \
        | grep '\.rpm$' 2>/dev/null) || true

    if [[ -z "$files" ]]; then
        # 备用方案：从文件名列表构建 raw URL
        warn "无法从 API 获取下载链接，尝试备用下载方式..."
        local names=""
        names=$(echo "$response" \
            | grep '"name"' 2>/dev/null \
            | sed 's/.*"name": "\(.*\)".*/\1/' 2>/dev/null \
            | grep '\.rpm$' 2>/dev/null) || true

        if [[ -n "$names" ]]; then
            files=""
            while IFS= read -r name; do
                if [[ -n "$files" ]]; then
                    files="${files}"$'\n'
                fi
                files="${files}${GITHUB_RAW}/${SELECTED_TRACK}/${version}/${name}"
            done <<< "$names"
        fi
    fi

    if [[ -z "$files" ]]; then
        die "无法获取版本 ${version} 的文件列表，请确认版本号是否正确"
    fi

    local total
    total=$(echo "$files" | wc -l)
    local count=0

    local curl_opts=("-fL" "--connect-timeout" "${CURL_CONNECT_TIMEOUT}" "--max-time" "${CURL_MAX_TIME}" "--retry" "${CURL_RETRY}")
    if [[ -t 1 ]]; then
        curl_opts+=("--progress-bar")
    else
        curl_opts+=("-sS")
    fi

    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        count=$((count + 1))
        local filename
        filename=$(basename "$url")
        echo -e "  [${count}/${total}] 下载 ${filename}..."
        if ! curl "${curl_opts[@]}" -o "${RPM_DIR}/${filename}" "$url"; then
            die "下载失败: ${filename}，请检查网络连接后重试"
        fi

        if [[ ! -s "${RPM_DIR}/${filename}" ]]; then
            die "下载的文件为空: ${filename}"
        fi
    done <<< "$files"

    info "所有 RPM 包下载完成 (共 ${count} 个)"

    # 下载 SHA256SUMS 校验文件
    local sha256_url="${GITHUB_RAW}/${SELECTED_TRACK}/${version}/SHA256SUMS"
    echo -e "  下载 SHA256SUMS..."
    if curl -fsSL \
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

        pushd "$rpm_dir" > /dev/null || die "无法进入目录: $rpm_dir"
        while IFS= read -r line; do
            # 跳过空行和注释
            [[ -z "$line" || "$line" == \#* ]] && continue

            local expected_hash file_name
            expected_hash=$(echo "$line" | awk '{print $1}')
            file_name=$(echo "$line" | awk '{print $2}')

            if [[ ! -f "$file_name" ]]; then
                echo -e "  ${RED}✗${NC} ${file_name} (文件不存在)"
                sha256_failed=$((sha256_failed + 1))
                continue
            fi

            local actual_hash
            actual_hash=$(sha256sum "$file_name" | awk '{print $1}')
            sha256_checked=$((sha256_checked + 1))

            if [[ "$actual_hash" == "$expected_hash" ]]; then
                echo -e "  ${GREEN}✓${NC} ${file_name} (SHA256)"
            else
                echo -e "  ${RED}✗${NC} ${file_name} (SHA256 不匹配)"
                echo -e "    预期: ${expected_hash}"
                echo -e "    实际: ${actual_hash}"
                sha256_failed=$((sha256_failed + 1))
            fi
        done < "$sha256_file"
        popd > /dev/null || true

        if [[ $sha256_failed -gt 0 ]]; then
            die "${sha256_failed} 个文件 SHA256 校验失败，文件可能已损坏或被篡改，请重新下载"
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
        total=$((total + 1))
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
            failed=$((failed + 1))
        fi
    done

    if [[ $total -eq 0 ]]; then
        die "目录中没有找到 RPM 包"
    fi

    if [[ $failed -gt 0 ]]; then
        die "${failed}/${total} 个包 RPM 校验失败，包文件可能已损坏，请重新下载"
    fi

    info "所有 RPM 包校验通过 (${total} 个)"
}

# ==================== 安装 RPM 包 ====================
install_rpms() {
    local rpm_dir="$1"
    local version="$2"

    step "准备安装 kernel-ml-${version}..."
    echo ""

    # 检查是否已安装相同版本（仅比较 Version，不绑定 Release）
    local installed_core_version
    installed_core_version=$(rpm -q --qf '%{VERSION}\n' kernel-ml-core 2>/dev/null | head -1 || true)
    if [[ "$installed_core_version" == "$version" ]]; then
        warn "kernel-ml-${version} 已经安装"
        local confirm
        prompt_yes_no "是否重新安装？(y/N): " "n" confirm
        if [[ "$confirm" != "y" ]]; then
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
        die "没有找到可安装的 RPM 包"
    fi

    # 检查核心包是否存在
    local has_core=false
    local _chk_bname
    for _chk_f in "${ordered_rpms[@]}"; do
        _chk_bname=$(basename "$_chk_f")
        if [[ "$_chk_bname" == kernel-ml-core-* ]]; then
            has_core=true
            break
        fi
    done

    if ! $has_core; then
        die "缺少核心包 kernel-ml-core，无法继续安装"
    fi

    if [[ ${#skipped[@]} -gt 0 ]]; then
        warn "以下包未找到，将跳过: ${skipped[*]}"
    fi

    echo "将按以下顺序安装:"
    echo ""
    local i=1
    for rpm_file in "${ordered_rpms[@]}"; do
        echo -e "  ${CYAN}${i}.${NC} $(basename "$rpm_file")"
        i=$((i + 1))
    done
    echo ""

    local confirm
    prompt_yes_no "确认安装？(Y/n): " "y" confirm
    if [[ "$confirm" == "n" ]]; then
        info "取消安装"
        exit 0
    fi

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo ""
        info "[DRY-RUN] 模拟安装以下包 (跳过实际安装):"
        local _dry_f
        for _dry_f in "${ordered_rpms[@]}"; do
            echo "  -> $(basename "$_dry_f")"
        done
        echo ""
        info "[DRY-RUN] kernel-ml-${version} 模拟安装完成！"
        return 0
    fi

    # 按顺序用 rpm -ivh 逐包安装（dnf/yum 不可用或失败时的回退方案）
    _rpm_sequential_install() {
        local _f _b
        for _f in "$@"; do
            _b=$(basename "$_f")
            echo -e "  安装 ${_b}..."
            rpm -ivh "$_f" || die "rpm 安装失败: ${_b}，可尝试手动运行: rpm -ivh --nodeps ${_b}"
        done
    }

    # 优先使用高级包管理器（自动处理依赖），失败时回退到 rpm 直接安装
    echo ""
    if command -v dnf &>/dev/null; then
        step "使用 dnf 安装（自动处理依赖）..."
        if ! dnf install -y "${ordered_rpms[@]}"; then
            warn "dnf 安装失败，回退到 rpm 顺序安装..."
            _rpm_sequential_install "${ordered_rpms[@]}"
        fi
    elif command -v yum &>/dev/null; then
        step "使用 yum 安装（自动处理依赖）..."
        if ! yum localinstall -y "${ordered_rpms[@]}"; then
            warn "yum 安装失败，回退到 rpm 顺序安装..."
            _rpm_sequential_install "${ordered_rpms[@]}"
        fi
    else
        step "使用 rpm 顺序安装..."
        _rpm_sequential_install "${ordered_rpms[@]}"
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
    if [[ "${TMP_CREATED:-0}" -eq 1 ]] \
       && [[ -n "${TMP_DIR:-}" ]] \
       && [[ -d "$TMP_DIR" ]] \
       && [[ "$TMP_DIR" == ${TMP_DIR_BASE}.* ]]; then
        rm -rf "$TMP_DIR" || true
        TMP_CREATED=0
    fi
}

on_interrupt() {
    echo ""
    warn "检测到中断信号，正在清理临时文件..."
    cleanup
    exit 130
}

# ==================== 主流程 ====================
main() {
    local version=""

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            -h|--help)
                echo "用法: $0 [--dry-run] [版本号]"
                echo "  --dry-run   模拟执行，不修改系统"
                exit 0
                ;;
            -*)
                error "未知参数: $1"
                exit 1
                ;;
            *)
                version="$1"
                shift
                ;;
        esac
    done

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        warn "已启用 --dry-run 模式，不会对系统进行实际修改"
    fi

    check_root
    check_system
    check_dependencies
    check_disk_space
    import_elrepo_key

    if [[ -n "$version" ]]; then
        # 命令行指定版本号：校验格式
        if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            error "版本号格式无效: $version"
            error "示例: 6.18.10"
            exit 1
        fi
        SELECTED_VERSION="$version"
        SELECTED_TRACK="ML"   # 命令行指定版本时默认使用 ML (MainLine) 轨道
        info "指定版本: kernel-ml-${SELECTED_VERSION} (轨道: ${SELECTED_TRACK})"
    else
        # 交互式选择
        select_version
    fi

    prepare_rpms "$SELECTED_VERSION"
    verify_rpms "$RPM_DIR"
    install_rpms "$RPM_DIR" "$SELECTED_VERSION"
    
    if [[ "${DRY_RUN}" -eq 0 ]]; then
        post_install "$SELECTED_VERSION"
    fi

    # 清理下载的临时文件
    cleanup
}

trap on_interrupt INT TERM
trap cleanup EXIT
main "$@"
