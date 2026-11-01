#!/usr/bin/env bash
# 仅用于你拥有或获授权使用的 Linux x86_64 主机。运行会消耗 CPU、电力与内存。
# 实际挖 RandomX/XMR，由 unMineable 转换结算 USDT（TRC20），不是直接挖 USDT。
# 文档：https://unmineable.com/coins/USDT
#       https://xmrig.com/docs/miner/hugepages
#       https://xmrig.com/docs/miner/command-line-options
set -Eeuo pipefail
umask 077

VERSION="6.24.0" # 保持原脚本版本，避免使用不固定的 latest
POOL="stratum+ssl://rx.unmineable.com:443"
WALLET="TMjqGd6h8yeh5xS8zk3yKw5BTT9b8b9Ldh"
WORKER=""
TAG="m82j-bq0u" # 保留原脚本推荐码；--tag '' 可以移除
SCREEN_NAME="xmrig"
ONE_GB=true
DRY_RUN=false
THREADS=""
INSTALL_DIR="${HOME:?HOME 未设置}/.local/share/dgwk-usdt"
TMP=""
cleanup() { if [[ -n "$TMP" ]]; then rm -rf -- "$TMP"; fi; }
trap cleanup EXIT
trap 'printf "错误：第 %s 行执行失败。\n" "$LINENO" >&2' ERR
fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
warn() { printf '提示：%s\n' "$*" >&2; }
usage() {
  cat <<'HELP'
用法：bash dgwk-usdt.sh [选项]
  --dry-run          仅打印配置，不下载、不安装、不改系统、不启动挖矿
  --wallet ADDRESS  覆盖默认 TRON/TRC20 钱包地址
  --worker NAME     指定矿工名；不指定则每次执行生成随机名称
  --tag CODE        推荐码（默认保留原码 m82j-bq0u）；--tag '' 移除
  --screen NAME     screen 会话名（默认 xmrig）
  --install-dir DIR 安装目录（默认 $HOME/.local/share/dgwk-usdt）
  --threads N       挖矿线程数（默认 nproc；不得超过当前可用逻辑 CPU 数）
  --no-1gb-pages    不请求 1GB 大页，仍启用普通大页
  -h, --help        帮助

运行：bash dgwk-usdt.sh
若希望 XMRig 自动申请系统大页，可在授权主机上执行：sudo bash dgwk-usdt.sh
root 权限并不保证大页成功；还取决于 CPU、内存碎片、内核及容器权限。
1GB 大页每个 NUMA 节点约需 3GB，普通大页还需要额外内存。
脚本不写入开机启动、不修改 GRUB/sysctl 配置文件、不创建定时任务。
为限制额外系统改动，默认关闭 MSR 寄存器优化；这不影响请求大页。
HELP
}
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --no-1gb-pages) ONE_GB=false; shift ;;
    -h|--help) usage; exit 0 ;;
    --wallet|--worker|--tag|--screen|--install-dir|--threads)
      (($# >= 2)) || fail "$1 缺少参数"
      case "$1" in
        --wallet) WALLET="$2" ;;
        --worker) WORKER="$2" ;;
        --tag) TAG="$2" ;;
        --screen) SCREEN_NAME="$2" ;;
        --install-dir) INSTALL_DIR="$2" ;;
        --threads) THREADS="$2" ;;
      esac
      shift 2 ;;
    *) fail "未知参数：$1（用 --help 查看用法）" ;;
  esac
done
[[ $(uname -s) == Linux ]] || fail '仅支持 Linux'
[[ $(uname -m) == x86_64 ]] || fail '原版下载包仅支持 x86_64，不能用于 ARM'
command -v nproc >/dev/null || fail '需要 nproc（coreutils）来检测可用逻辑 CPU 数'
AVAILABLE_THREADS=$(nproc)
[[ $AVAILABLE_THREADS =~ ^[1-9][0-9]{0,5}$ ]] || fail 'nproc 未返回有效线程数'
[[ -n $THREADS ]] || THREADS="$AVAILABLE_THREADS"
[[ $THREADS =~ ^[1-9][0-9]{0,5}$ ]] || fail '--threads 必须是正整数'
((THREADS <= AVAILABLE_THREADS)) || fail "--threads 不得超过可用逻辑 CPU 数 $AVAILABLE_THREADS"
[[ $WALLET =~ ^T[1-9A-HJ-NP-Za-km-z]{33}$ ]] || fail '钱包必须是 34 位 TRON Base58 地址（此处仅检查格式，不验证归属）'
if [[ -z $WORKER ]]; then
  RANDOM_HEX=$(od -An -N8 -tx1 /dev/urandom)
  RANDOM_HEX=${RANDOM_HEX//[[:space:]]/}
  WORKER="worker_${RANDOM_HEX}"
fi
[[ $WORKER =~ ^[A-Za-z0-9_-]{1,64}$ ]] || fail '矿工名仅允许 1–64 位字母、数字、下划线、连字符'
[[ -z $TAG || $TAG =~ ^[A-Za-z0-9-]{1,64}$ ]] || fail '推荐码格式错误'
[[ $SCREEN_NAME =~ ^[A-Za-z0-9_-]{1,64}$ ]] || fail 'screen 名称格式错误'
[[ -n $INSTALL_DIR && $INSTALL_DIR != *$'\n'* ]] || fail '安装目录无效'
USER_STRING="USDT:${WALLET}.${WORKER}"
[[ -z $TAG ]] || USER_STRING+="#${TAG}"

printf '=== XMRig / RandomX → USDT（TRC20）===\n'
printf '矿池：%s\n钱包：%s\n随机/指定矿工：%s\n矿池用户名：%s\n' "$POOL" "$WALLET" "$WORKER" "$USER_STRING"
printf '普通大页：开启；请求 1GB 大页：%s\n' "$ONE_GB"
printf '挖矿线程：%s；可用逻辑 CPU：%s（nproc）\n' "$THREADS" "$AVAILABLE_THREADS"
warn 'USDT 不是可挖的 PoW 币；实际挖 XMR，由矿池转换结算。请确认钱包能接收 USDT-TRC20。'
if [[ $ONE_GB == true ]]; then
  warn '已请求 1GB 大页，不代表系统已经成功分配；内存不足时可用 --no-1gb-pages。'
  if ! grep -qw pdpe1gb /proc/cpuinfo; then
    warn 'CPU 未报告 pdpe1gb，1GB 大页可能不可用。'
  fi
fi
if ((EUID != 0)); then
  warn '当前非 root；只会尝试使用系统已有大页。要自动申请大页，请在授权主机上用 sudo 运行。'
else
  warn 'XMRig 将以 root 运行，可能自动临时预留内核大页；停止后预留不一定立即释放，重启可清除临时预留。'
fi

# 生成独立配置，不复用下载包内的旧钱包或旧矿池配置。
# 普通大页用 JSON huge-pages:true；XMRig 没有 --huge-pages 开启参数。
render_config() {
  python3 - "$POOL" "$USER_STRING" "$ONE_GB" "$THREADS" <<'PY'
import json, sys
pool, user, one_gb, threads = sys.argv[1:]
print(json.dumps({
    "autosave": False,
    "background": False,
    "cpu": {"enabled": True, "huge-pages": True, "rx": [-1] * int(threads)},
    "randomx": {"1gb-pages": one_gb == "true", "wrmsr": False, "rdmsr": False},
    "opencl": False,
    "cuda": False,
    "pools": [{"algo": "rx/0", "url": pool, "user": user,
               "pass": "x", "keepalive": True}],
    "print-time": 60
}, ensure_ascii=False, indent=2))
PY
}
if [[ $DRY_RUN == true ]]; then
  command -v python3 >/dev/null || fail '预览需要 python3；未执行任何安装'
  render_config
  printf '\n预览完成：未下载、未安装、未修改系统、未启动挖矿。\n'
  exit 0
fi

# 依赖只在真实运行时安装；无 root 权限则提示，而不是自动提权。
MISSING=()
command -v curl >/dev/null || MISSING+=(curl)
command -v screen >/dev/null || MISSING+=(screen)
command -v python3 >/dev/null || MISSING+=(python3)
command -v sha256sum >/dev/null || MISSING+=(coreutils)
command -v tar >/dev/null || MISSING+=(tar)
if ((${#MISSING[@]})); then
  if ((EUID != 0)) || ! command -v apt-get >/dev/null; then
    fail "请先安装依赖后重试：${MISSING[*]}（本脚本只自动安装 Debian/Ubuntu 依赖）"
  fi
  apt-get update
  apt-get install -y ca-certificates "${MISSING[@]}"
fi

# 不自动关闭已有挖矿会话，避免影响用户其他任务。
session_exists() {
  screen -ls 2>/dev/null | awk -v name="$SCREEN_NAME" '
    $1 ~ /^[0-9]+\./ { id=$1; sub(/^[0-9]+\./, "", id); if (id==name) found=1 }
    END { exit !found }'
}
if session_exists; then
  fail "screen 会话 $SCREEN_NAME 已存在；先手动停止，或用 --screen 指定新名称"
fi
mkdir -p -- "$INSTALL_DIR"
INSTALL_DIR=$(cd -- "$INSTALL_DIR" && pwd -P)
# 所有下载都进临时目录，校验成功后才解压；每次运行重新验证官方包。
TMP=$(mktemp -d "$INSTALL_DIR/.download.XXXXXXXX")
TARBALL="xmrig-${VERSION}-linux-static-x64.tar.gz"
BASE_URL="https://github.com/xmrig/xmrig/releases/download/v${VERSION}"
curl -fL --retry 3 --connect-timeout 20 "$BASE_URL/$TARBALL" -o "$TMP/$TARBALL"
curl -fL --retry 3 --connect-timeout 20 "$BASE_URL/SHA256SUMS" -o "$TMP/SHA256SUMS"
EXPECTED=$(awk -v file="$TARBALL" '{name=$2; sub(/^\*/, "", name); if(name==file) print $1}' "$TMP/SHA256SUMS")
[[ $EXPECTED =~ ^[[:xdigit:]]{64}$ ]] || fail '官方清单没有唯一的有效 SHA256 值'
printf '%s  %s\n' "$EXPECTED" "$TARBALL" > "$TMP/verify.sha256"
(cd -- "$TMP" && sha256sum -c verify.sha256)
# 仅提取所需可执行文件，不提取归档内其他配置。
tar -xzf "$TMP/$TARBALL" -C "$TMP" "xmrig-${VERSION}/xmrig"
RUN_DIR=$(mktemp -d "$INSTALL_DIR/run.XXXXXXXX")
MINER="$RUN_DIR/xmrig"
CONFIG="$RUN_DIR/config.json"
LOG="$RUN_DIR/xmrig.log"
install -m 0755 "$TMP/xmrig-${VERSION}/xmrig" "$MINER"
render_config > "$CONFIG"
ARGS=(--config "$CONFIG" --log-file "$LOG" --no-color)
if [[ $ONE_GB == true ]]; then ARGS+=(--randomx-1gb-pages); fi
screen -dmS "$SCREEN_NAME" "$MINER" "${ARGS[@]}"
sleep 2
if ! session_exists; then
  [[ ! -f $LOG ]] || tail -n 40 -- "$LOG"
  fail "启动后 screen 会话不存在，请检查配置、权限及日志：$LOG"
fi
printf '\nscreen 会话已建立（不代表已连接矿池或大页成功）：%s\n' "$SCREEN_NAME"
printf '配置：%s\n日志：%s\n' "$CONFIG" "$LOG"
printf '查看：screen -r %s\n停止：screen -S %s -X quit\n' "$SCREEN_NAME" "$SCREEN_NAME"
printf '脱离 screen：Ctrl+A，然后 D\n'
printf '请在日志中确认 accepted、huge pages 100%% 及 1GB PAGES/数据集分配状态；仅显示 supported 不代表已用上。\n'
