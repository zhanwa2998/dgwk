#!/usr/bin/env bash
set -euo pipefail

# ================== 默认参数 ==================
XMRIg_VERSION="6.24.0"
TARBALL="xmrig-${XMRIg_VERSION}-linux-static-x64.tar.gz"
URL="https://github.com/xmrig/xmrig/releases/download/v${XMRIg_VERSION}/${TARBALL}"
SCREEN_NAME="xmrig"

# 默认值，可在命令行传参覆盖
POOL="stratum+ssl://rx.unmineable.com:443"
COIN="DOGE"
WALLET="DLh4nNA4fn8kGbiNvjnL87yh287V5PPFQo"
WORKER=""
TAG="m82j-bq0u"
PASSWORD="x"
# ==============================================

# ============= 解析命令行参数 =================
while [[ $# -gt 0 ]]; do
  case $1 in
    --pool) POOL="$2"; shift 2 ;;
    --coin) COIN="$2"; shift 2 ;;
    --wallet) WALLET="$2"; shift 2 ;;
    --worker) WORKER="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --pass) PASSWORD="$2"; shift 2 ;;
    --screen) SCREEN_NAME="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done
# ==============================================

# 未通过 --worker 指定时，每次启动生成一个随机 worker 名
if [[ -z "$WORKER" ]]; then
  RANDOM_SUFFIX="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  WORKER="worker-${RANDOM_SUFFIX}"
fi

echo "=== 一键 xmrig 安装并启动（参数化版本） ==="
echo "配置:"
echo "  矿池:   $POOL"
echo "  币种:   $COIN"
echo "  钱包:   $WALLET"
echo "  Worker: $WORKER"
echo "  Tag:    $TAG"
echo "  Screen: $SCREEN_NAME"
echo

# Step 1: 下载 xmrig
if [ ! -f "$TARBALL" ]; then
  echo "Step 1: 下载 xmrig..."
  wget --no-verbose "$URL" -O "$TARBALL"
else
  echo "Step 1: 已存在 $TARBALL，跳过下载。"
fi

# Step 2: 解压
if [ ! -d "xmrig-${XMRIg_VERSION}" ]; then
  echo "Step 2: 解压..."
  tar -zxvf "$TARBALL"
else
  echo "Step 2: 已存在 xmrig-${XMRIg_VERSION}，跳过解压。"
fi

# Step 3: 安装 screen
 echo "Step 3: 检查 screen..."
if ! command -v screen >/dev/null 2>&1; then
  echo "  未安装，正在安装..."
  if command -v sudo >/dev/null 2>&1; then
    sudo apt-get update -y && sudo apt-get install -y screen
  else
    apt-get update -y && apt-get install -y screen
  fi
else
  echo "  已安装。"
fi

# Step 4: 准备目录
cd "xmrig-${XMRIg_VERSION}"
chmod +x xmrig
cd ..

# Step 5: 启动 miner
CMD="./xmrig -a rx -o ${POOL} -u ${COIN}:${WALLET}.${WORKER}#${TAG} -p ${PASSWORD}"

# 如果已有同名 screen 会话则关闭
if screen -list | grep -q "\.${SCREEN_NAME}\\b\\|\\b${SCREEN_NAME}\\s"; then
  screen -S "$SCREEN_NAME" -X quit || true
  sleep 1
fi

echo "Step 5: 启动 xmrig ..."
screen -dmS "$SCREEN_NAME" bash -c "cd xmrig-${XMRIg_VERSION} && exec $CMD"

echo
echo "✅ 已启动 miner (screen 名称: $SCREEN_NAME, worker: $WORKER)"
echo "查看:   screen -r $SCREEN_NAME"
echo "后台:   Ctrl+A+D"
echo "退出:   screen -S $SCREEN_NAME -X quit"
