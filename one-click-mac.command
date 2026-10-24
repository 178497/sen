#!/bin/bash
# 森 · macOS 一键安装（加固版）
#
#   curl -fL --max-time 30 --retry 2 -o ~/sen-install.command \
#     https://178497.github.io/sen/one-click-mac.command
#   shasum -a 256 ~/sen-install.command      # 应与页面上的值一致
#   chmod +x ~/sen-install.command && ~/sen-install.command
#
# 会自动完成：装 uv → 装独立 Python 3.12 → 装依赖 → 打包 .app → 装进「应用程序」→ 启动
# 不需要提前装 Python、Homebrew 或 Xcode 开发者工具。
#
# 选项：
#   --dry-run   只做环境自检，不下载、不安装
#   --yes       全程不问，适合远程指导
#   --rebuild   重新下载源码并重建（默认复用已校验的源码包）
#   --help
#
# 日志：~/sen-install.log（失败时会告诉你路径）

set -uo pipefail

APP_VERSION="0.1.39"
SRC_SHA256="${SEN_SRC_SHA256:-9fef07ad87efb53bb4f659c3746fd3e5d7b630c70a0890c2e16c90d111e219f5}"
ZIP_PRIMARY="https://178497.github.io/sen/sen-src-${APP_VERSION}.zip"
ZIP_FALLBACK="https://github.com/178497/sen/releases/download/v${APP_VERSION}-source/sen-src-${APP_VERSION}.zip"
OLLAMA_DMG="https://ollama.com/download/Ollama.dmg"
UV_MIRROR_PY="https://mirrors.tuna.tsinghua.edu.cn/github-release/astral-sh/python-build-standalone/20241016"
UPDATE_URLS="https://178497.github.io/sen/latest.json
https://raw.githubusercontent.com/178497/sen/main/latest.json"

WORK="${SEN_HOME:-$HOME/sen}"
LOG="${SEN_LOG:-$HOME/sen-install.log}"
DRY_RUN=0
ASSUME_YES=0
REBUILD=0
MIN_MACOS=11
MIN_DISK_MB=$((6 * 1024))

# ---------------------------------------------------------------- 输出
if [ -t 1 ]; then
  C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_0=$'\033[0m'
else
  C_G=""; C_Y=""; C_R=""; C_0=""
fi
say()  { printf '\n%s==>%s %s\n' "$C_G" "$C_0" "$1"; }
warn() { printf '%s  ! %s%s\n' "$C_Y" "$1" "$C_0"; }
info() { printf '    %s\n' "$1"; }

finish_and_exit() {
  local code=$1
  if [ "$code" -ne 0 ]; then
    printf '日志：%s\n' "$LOG"
    printf '要发诊断，运行源码目录里的 ./collect-mac-logs.command\n'
    if [ -t 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
      printf '按回车关闭…'
      read -r _ || true
    fi
  fi
  exit "$code"
}

die()  { printf '\n%s失败：%s%s\n' "$C_R" "$1" "$C_0"; finish_and_exit 1; }
on_signal() { printf '\n已中断。\n'; finish_and_exit 130; }
trap on_signal INT TERM

# 明确区分「必须成功」和「尽力而为」，不再用全局 ERR trap
run()  { "$@" || die "第 $LINENO 行执行失败：$*"; }
soft() { "$@" >/dev/null 2>&1 || true; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1"; }

# ---------------------------------------------------------------- 参数
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --rebuild) REBUILD=1 ;;
    --help|-h)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "未知参数：${arg}（用 --help 看用法）" ;;
  esac
done

# 日志：所有输出同时写进文件，测试者只要回传一个文件
if ! ( : >> "$LOG" ) 2>/dev/null; then
  LOG="/tmp/sen-install-$(date +%s).log"
fi
exec > >(tee -a "$LOG") 2>&1 || true
printf '\n===== %s =====\n' "$(date '+%Y-%m-%d %H:%M:%S')"

echo "=============================="
echo "  森 · macOS 一键安装  $APP_VERSION"
echo "=============================="

# ---------------------------------------------------------------- 0. 系统检查
say "系统检查"
MACOS_VER="$(sw_vers -productVersion 2>/dev/null || echo 0)"
MACOS_MAJOR="${MACOS_VER%%.*}"
ARCH="$(uname -m)"
info "macOS $MACOS_VER · $ARCH · 用户 $USER"

[ "$MACOS_MAJOR" -ge "$MIN_MACOS" ] 2>/dev/null \
  || die "需要 macOS ${MIN_MACOS}+，当前是 $MACOS_VER"

if [ "$ARCH" = "x86_64" ]; then
  warn "这是 Intel Mac：能装，但本地模型推理会很慢"
elif [ "$ARCH" != "arm64" ]; then
  die "不支持的架构：$ARCH"
fi

FREE_MB="$(df -Pk "$HOME" | awk 'NR==2 {print int($4/1024)}')"
info "可用磁盘 ${FREE_MB} MB"
[ "${FREE_MB:-0}" -ge "$MIN_DISK_MB" ] \
  || die "磁盘空间不足，至少需要 ${MIN_DISK_MB} MB（当前 ${FREE_MB} MB）"

need curl; need unzip; need shasum
# sips/iconutil/codesign 是系统自带；缺了也只是少个图标，不拦

if ! curl -fsS --max-time 10 -o /dev/null -I "$ZIP_PRIMARY" 2>/dev/null; then
  warn "主下载源连不上，稍后会改用 GitHub Release"
fi

have_sudo=0
if sudo -n true 2>/dev/null; then have_sudo=1; fi
info "免密 sudo：$([ "$have_sudo" -eq 1 ] && echo 是 || echo 否)"

if [ "$DRY_RUN" -eq 1 ]; then
  say "自检通过（--dry-run，不执行安装）"
  info "源码：$ZIP_PRIMARY"
  info "目录：$WORK"
  finish_and_exit 0
fi

# ---------------------------------------------------------------- 1. 源码包
say "获取源码包 $APP_VERSION"
mkdir -p "$WORK" || die "无法创建 $WORK"
SRC_MARK="$WORK/.sen-src.sha256"

already="$(cat "$SRC_MARK" 2>/dev/null || true)"
if [ "$REBUILD" -eq 0 ] && [ "$already" = "$SRC_SHA256" ] && [ -f "$WORK/desktop.py" ]; then
  info "已存在校验通过的源码，跳过下载（--rebuild 可强制重下）"
else
  tmpzip="$(mktemp -d)/sen-src.zip"
  if ! curl -fL --max-time 300 --retry 2 -o "$tmpzip" "$ZIP_PRIMARY"; then
    warn "主地址失败，改用 GitHub Release"
    curl -fL --max-time 300 --retry 2 -o "$tmpzip" "$ZIP_FALLBACK" \
      || die "源码包下载失败，检查网络后重试"
  fi
  got="$(shasum -a 256 "$tmpzip" | awk '{print $1}')"
  if [ "$got" != "$SRC_SHA256" ]; then
    rm -f "$tmpzip"
    die "源码包校验失败（期望 $SRC_SHA256，实际 ${got}），已中止"
  fi
  info "SHA-256 校验通过"
  rm -rf "$WORK/desktop.py"
  unzip -oq "$tmpzip" -d "$WORK" || die "解压失败"
  rm -f "$tmpzip"
  printf '%s\n' "$SRC_SHA256" > "$SRC_MARK"
fi

cd "$WORK" || die "进入 $WORK 失败"
say "源码就绪：$WORK"

printf '%s\n' "$UPDATE_URLS" > update_url.txt
printf '%s\n' "$APP_VERSION" > VERSION

# ---------------------------------------------------------------- 2. uv
say "准备 uv"
if command -v uv >/dev/null 2>&1; then
  info "已安装：$(uv --version 2>/dev/null | head -1)"
elif [ -x "$HOME/.local/bin/uv" ]; then
  export PATH="$HOME/.local/bin:$PATH"
  info "已安装：$(uv --version 2>/dev/null | head -1)"
else
  case "$ARCH" in
    arm64) uv_arch="aarch64" ;;
    *)     uv_arch="x86_64" ;;
  esac
  uv_base="https://github.com/astral-sh/uv/releases/latest/download"
  uv_tar="uv-${uv_arch}-apple-darwin.tar.gz"
  uv_tmp="$(mktemp -d)"
  info "下载官方二进制并校验"
  if curl -fL --max-time 300 --retry 2 -o "$uv_tmp/$uv_tar" "$uv_base/$uv_tar" \
   && curl -fL --max-time 60 --retry 2 -o "$uv_tmp/$uv_tar.sha256" "$uv_base/$uv_tar.sha256" \
   && ( cd "$uv_tmp" && shasum -a 256 -c "$uv_tar.sha256" >/dev/null 2>&1 ); then
    tar -xzf "$uv_tmp/$uv_tar" -C "$uv_tmp" || die "uv 解包失败"
    mkdir -p "$HOME/.local/bin"
    cp "$uv_tmp/uv-${uv_arch}-apple-darwin/uv" "$HOME/.local/bin/uv" || die "uv 复制失败"
    chmod +x "$HOME/.local/bin/uv"
    export PATH="$HOME/.local/bin:$PATH"
  else
    warn "二进制下载或校验失败，退回官方安装脚本（会执行远程脚本，自行判断）"
    curl -LsSf --max-time 300 https://astral.sh/uv/install.sh | sh \
      || die "uv 安装失败，请手动安装后重试：https://docs.astral.sh/uv/"
    export PATH="$HOME/.local/bin:$PATH"
  fi
  rm -rf "$uv_tmp"
fi
command -v uv >/dev/null 2>&1 || die "uv 装好了但不在 PATH 里，开个新终端重试"

# ---------------------------------------------------------------- 3. Python 3.12
say "准备独立 Python 3.12"
if [ ! -x ".venv-mac/bin/python" ] || [ "$REBUILD" -eq 1 ]; then
  rm -rf .venv-mac
  if ! uv venv --python 3.12 .venv-mac >/dev/null 2>&1; then
    warn "默认源失败，改用清华镜像"
    UV_PYTHON_INSTALL_MIRROR="$UV_MIRROR_PY" uv venv --python 3.12 .venv-mac \
      || die "Python 3.12 下载失败"
  fi
fi
PY=".venv-mac/bin/python"
[ -x "$PY" ] || die "虚拟环境创建失败"
info "$("$PY" -V 2>&1)"

# ---------------------------------------------------------------- 4. 依赖
say "安装依赖（约 2-4 分钟）"
REQ="requirements-desktop.txt"
[ -f "$REQ" ] || die "源码包里缺少 $REQ"
if ! uv pip install --python "$PY" -r "$REQ" pyinstaller==6.16.0 >/dev/null 2>&1; then
  warn "直连失败，改用清华镜像"
  uv pip install --python "$PY" -i https://pypi.tuna.tsinghua.edu.cn/simple \
    -r "$REQ" pyinstaller==6.16.0 || die "依赖安装失败"
fi
say "依赖就绪"

# ---------------------------------------------------------------- 5. 图标
if [ -f "static/assistant-256.png" ] && [ ! -f "static/assistant.icns" ]; then
  say "生成图标"
  ICONSET="build/assistant.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    soft sips -z $size $size static/assistant-256.png --out "$ICONSET/icon_${size}x${size}.png"
    soft sips -z $((size*2)) $((size*2)) static/assistant-256.png --out "$ICONSET/icon_${size}x${size}@2x.png"
  done
  soft iconutil -c icns "$ICONSET" -o static/assistant.icns
  [ -f "static/assistant.icns" ] || warn "图标生成失败，用默认图标（不影响功能）"
fi

# ---------------------------------------------------------------- 6. 打包
say "打包 .app（2-4 分钟，别关窗口）"
rm -rf build dist
"$PY" -m PyInstaller sen_mac.spec --noconfirm --clean --log-level=WARN >/tmp/sen-build.log 2>&1
if [ $? -ne 0 ]; then
  warn "构建失败，日志如下（完整版 /tmp/sen-build.log）"
  tail -30 /tmp/sen-build.log
  die "PyInstaller 失败"
fi
[ -x "dist/Sen.app/Contents/MacOS/Sen" ] || die "没有生成可执行文件"

missing=""
for f in train.sh setup_train.sh select_model.py check_env.py merge_adapter.py \
         image_worker.py train_qlora.py prepare_oneclick_data.py requirements-train.txt; do
  find dist/Sen.app -name "$f" -print -quit 2>/dev/null | grep -q . || missing="$missing $f"
done
[ -z "$missing" ] || die "打包缺少文件:$missing"
say "打包完成"

# ---------------------------------------------------------------- 7. 签名
say "ad-hoc 签名"
if codesign --force --deep --sign - dist/Sen.app >/dev/null 2>&1; then
  if codesign --verify --deep --strict dist/Sen.app >/dev/null 2>&1; then
    info "签名校验通过"
  else
    warn "签名写入成功但校验未通过，仍可尝试安装"
  fi
else
  warn "签名失败，首次打开可能被系统拦下"
fi

# ---------------------------------------------------------------- 8. 安装
say "安装到「应用程序」"
DEST="/Applications/Sen.app"
if [ -w "/Applications" ]; then
  soft rm -rf "$DEST"
  run cp -R "dist/Sen.app" "/Applications/"
else
  warn "需要管理员权限写入 /Applications"
  if [ "$ASSUME_YES" -eq 1 ]; then
    run sudo rm -rf "$DEST"
    run sudo cp -R "dist/Sen.app" "/Applications/"
  else
    sudo rm -rf "$DEST" && sudo cp -R "dist/Sen.app" "/Applications/" \
      || die "复制到 /Applications 失败（可以手动把 dist/Sen.app 拖进去）"
  fi
fi
soft xattr -dr com.apple.quarantine "$DEST"
[ -d "$DEST" ] || die "安装后找不到 $DEST"
say "已安装 $DEST"

# ---------------------------------------------------------------- 9. Ollama
say "检查 Ollama"
if [ -d "/Applications/Ollama.app" ] || command -v ollama >/dev/null 2>&1; then
  info "已安装"
else
  info "未安装，正在下载（本地推理引擎，必需）"
  if curl -fL --max-time 600 --retry 2 -o /tmp/Ollama.dmg "$OLLAMA_DMG"; then
    if hdiutil attach /tmp/Ollama.dmg -nobrowse -quiet 2>/dev/null; then
      if [ -d "/Volumes/Ollama/Ollama.app" ]; then
        if [ -w "/Applications" ]; then
          soft cp -R "/Volumes/Ollama/Ollama.app" "/Applications/"
        else
          soft sudo cp -R "/Volumes/Ollama/Ollama.app" "/Applications/"
        fi
        soft xattr -dr com.apple.quarantine /Applications/Ollama.app
      fi
      soft hdiutil detach "/Volumes/Ollama" -quiet
    fi
    rm -f /tmp/Ollama.dmg
    [ -d "/Applications/Ollama.app" ] || warn "Ollama 复制失败，请手动拖入「应用程序」"
  else
    warn "Ollama 下载失败，请手动安装：https://ollama.com/download/mac"
  fi
fi

# ---------------------------------------------------------------- 10. 启动
say "启动森"
soft open -a Sen

echo
echo "=============================="
echo "  完成"
echo "=============================="
echo "· 应用：/Applications/Sen.app"
echo "· 数据：~/Library/Application Support/Sen"
echo "· 日志：$LOG"
echo "· 首次打开如果被系统拦下："
echo "    macOS 14 及更早：右键 Sen.app → 打开"
echo "    macOS 15 及更新：系统设置 → 隐私与安全性 → 「仍要打开」"
echo "· 对话前需要在应用内下载模型（约 1.4 GB）"
echo

if [ -t 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
  printf '按回车关闭…'
  read -r _ || true
fi
exit 0
