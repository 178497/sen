#!/bin/bash
# 森 · macOS 一键安装
#
#   curl -L -o ~/sen-install.command https://178497.github.io/sen/one-click-mac.command
#   chmod +x ~/sen-install.command && ~/sen-install.command
#
# 会自动完成：装 uv → 装独立 Python 3.12 → 装依赖 → 打包 .app → 装进「应用程序」→ 启动
# 不需要提前装 Python、Homebrew 或 Xcode 开发者工具。

set -uo pipefail

ZIP_URL="https://178497.github.io/sen/sen-src-0.1.38.zip"
ZIP_FALLBACK="https://github.com/178497/sen/releases/download/v0.1.38-source/sen-src-0.1.38.zip"
OLLAMA_DMG="https://ollama.com/download/Ollama.dmg"
WORK="$HOME/sen"
UV_MIRROR_PY="https://mirrors.tuna.tsinghua.edu.cn/github-release/astral-sh/python-build-standalone/20241016"

say()  { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$1"; }
die()  { printf '\n\033[1;31m失败：%s\033[0m\n' "$1"; echo; read -r -p "按回车关闭…"; exit 1; }

trap 'die "第 $LINENO 行出错"' ERR

echo "=============================="
echo "  森 · macOS 一键安装"
echo "=============================="
echo "macOS $(sw_vers -productVersion 2>/dev/null) · $(uname -m)"
echo "目录 $WORK"

# ---------------------------------------------------------------- 0. 架构
if [ "$(uname -m)" != "arm64" ]; then
  warn "这是 Intel Mac，能装但本地模型会很慢"
fi

# ---------------------------------------------------------------- 1. 源码
if [ ! -f "$WORK/desktop.py" ]; then
  say "下载源码包"
  mkdir -p "$WORK"
  tmpzip="$(mktemp -d)/src.zip"
  if ! curl -fL --max-time 300 -o "$tmpzip" "$ZIP_URL"; then
    warn "主地址失败，换 GitHub"
    curl -fL --max-time 300 -o "$tmpzip" "$ZIP_FALLBACK" || die "源码包下载失败，检查网络"
  fi
  unzip -oq "$tmpzip" -d "$WORK" || die "解压失败"
fi
cd "$WORK" || die "进入 $WORK 失败"
say "源码就绪：$WORK"

# ---------------------------------------------------------------- 2. uv
if ! command -v uv >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/uv" ]; then
  say "安装 uv（不需要管理员权限）"
  if ! curl -LsSf --max-time 300 https://astral.sh/uv/install.sh | sh >/dev/null 2>&1; then
    warn "官方脚本失败，直接下载二进制"
    arch="aarch64"; [ "$(uname -m)" = "x86_64" ] && arch="x86_64"
    mkdir -p "$HOME/.local/bin"
    curl -fL --max-time 300 -o /tmp/uv.tgz \
      "https://github.com/astral-sh/uv/releases/latest/download/uv-${arch}-apple-darwin.tar.gz" \
      || die "uv 下载失败"
    tar -xzf /tmp/uv.tgz -C /tmp
    cp "/tmp/uv-${arch}-apple-darwin/uv" "$HOME/.local/bin/uv"
    chmod +x "$HOME/.local/bin/uv"
  fi
fi
export PATH="$HOME/.local/bin:$PATH"
command -v uv >/dev/null 2>&1 || die "uv 装好了但 PATH 里找不到，执行 source ~/.zshrc 后重试"
say "uv $(uv --version 2>/dev/null | awk '{print $2}')"

# ---------------------------------------------------------------- 3. Python 3.12
say "准备独立 Python 3.12"
if [ ! -x ".venv-mac/bin/python" ]; then
  if ! uv venv --python 3.12 .venv-mac >/dev/null 2>&1; then
    warn "默认源失败，改用清华镜像"
    UV_PYTHON_INSTALL_MIRROR="$UV_MIRROR_PY" uv venv --python 3.12 .venv-mac \
      || die "Python 3.12 下载失败"
  fi
fi
PY=".venv-mac/bin/python"
[ -x "$PY" ] || die "虚拟环境创建失败"
say "$("$PY" -V)"

# ---------------------------------------------------------------- 4. 依赖
say "安装依赖（约 2-4 分钟）"
REQ="requirements-desktop.txt"
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
  mkdir -p "$ICONSET"
  for size in 16 32 64 128 256 512; do
    sips -z $size $size static/assistant-256.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
    sips -z $((size*2)) $((size*2)) static/assistant-256.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o static/assistant.icns >/dev/null 2>&1 || warn "图标生成失败，用默认图标"
fi

# ---------------------------------------------------------------- 6. 打包
say "打包 .app（2-4 分钟，别关窗口）"
printf '%s\n' "0.1.38" > VERSION
cat > update_url.txt <<EOF
https://178497.github.io/sen/latest.json
https://178497.github.io/sen/manifest/latest.json
https://raw.githubusercontent.com/178497/sen/main/latest.json
EOF
rm -rf build dist
"$PY" -m PyInstaller sen_mac.spec --noconfirm --clean --log-level=WARN >/tmp/sen-build.log 2>&1 \
  || { warn "构建失败，日志见 /tmp/sen-build.log"; tail -30 /tmp/sen-build.log; die "PyInstaller 失败"; }

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
codesign --force --deep --sign - dist/Sen.app >/dev/null 2>&1 || warn "签名失败，仍可用（首次需右键打开）"

# ---------------------------------------------------------------- 8. 安装
say "安装到「应用程序」"
rm -rf "/Applications/Sen.app" 2>/dev/null
if ! cp -R "dist/Sen.app" "/Applications/" 2>/dev/null; then
  warn "需要管理员权限"
  sudo rm -rf "/Applications/Sen.app"
  sudo cp -R "dist/Sen.app" "/Applications/" || die "复制到 /Applications 失败"
fi
xattr -dr com.apple.quarantine "/Applications/Sen.app" 2>/dev/null
say "已安装 /Applications/Sen.app"

# ---------------------------------------------------------------- 9. Ollama
if [ ! -d "/Applications/Ollama.app" ] && ! command -v ollama >/dev/null 2>&1; then
  say "安装 Ollama（本地推理引擎，必需）"
  if curl -fL --max-time 600 -o /tmp/Ollama.dmg "$OLLAMA_DMG"; then
    hdiutil attach /tmp/Ollama.dmg -nobrowse -quiet 2>/dev/null
    vol="/Volumes/Ollama"
    if [ -d "$vol/Ollama.app" ]; then
      cp -R "$vol/Ollama.app" /Applications/ 2>/dev/null \
        || { sudo cp -R "$vol/Ollama.app" /Applications/ || warn "Ollama 复制失败，请手动拖入"; }
      xattr -dr com.apple.quarantine /Applications/Ollama.app 2>/dev/null
    fi
    hdiutil detach "$vol" -quiet 2>/dev/null
    rm -f /tmp/Ollama.dmg
  else
    warn "Ollama 下载失败，请手动安装：https://ollama.com/download/mac"
  fi
fi

# ---------------------------------------------------------------- 10. 启动
say "启动森"
open -a Sen
echo
echo "=============================="
echo "  完成"
echo "=============================="
echo "· 应用：/Applications/Sen.app"
echo "· 数据：~/Library/Application Support/Sen"
echo "· 首次打开如果被系统拦下：右键 Sen.app → 打开"
echo "· 对话前需要下载模型（应用内会引导，约 1.4 GB）"
echo
read -r -p "按回车关闭…"
