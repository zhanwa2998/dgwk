#!/usr/bin/env bash
set -euo pipefail

# ================== 默认参数 ==================
XMRIg_VERSION="6.24.0"
TARBALL="xmrig-${XMRIg_VERSION}-linux-static-x64.tar.gz"
URL="https://github.com/xmrig/xmrig/releases/download/v${XMRIg_VERSION}/${TARBALL}"
SCREEN_NAME="xmrig"

# RandomX 需要 1,168 个 2 MiB huge pages（约 2.28 GiB）。
REQUIRED_HUGEPAGES=1168
HUGEPAGES_SYSFS="/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages"
HUGETLB_GROUP_SYSFS="/proc/sys/vm/hugetlb_shm_group"

# 默认值，可在命令行传参覆盖
POOL="stratum+ssl://rx.unmineable.com:443"
COIN="DOGE"
WALLET="DLh4nNA4fn8kGbiNvjnL87yh287V5PPFQo"
WORKER=""
THREADS="8"
TAG="m82j-bq0u"
PASSWORD="x"
RESTORE_HUGEPAGES=0
# ==============================================

usage() {
  cat <<'EOF'
用法: ./zx.sh [启动参数]
  --pool URL --coin 币种 --wallet 钱包 --worker 名称
  --threads 数量 --tag 标签 --pass 密码 --screen 会话名
  --restore-hugepages [--screen 会话名]

大页由脚本通过 sudo 临时预留；XMRig 本身始终以当前普通用户运行。
停止挖矿并退出对应 screen 会话后，运行 --restore-hugepages 恢复启动前的大页数量。
EOF
}

# ============= 解析命令行参数 =================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pool|--coin|--wallet|--worker|--threads|--tag|--pass|--screen)
      if [[ $# -lt 2 ]]; then echo "参数 $1 缺少值。" >&2; usage >&2; exit 2; fi
      case "$1" in
        --pool) POOL="$2" ;;
        --coin) COIN="$2" ;;
        --wallet) WALLET="$2" ;;
        --worker) WORKER="$2" ;;
        --threads) THREADS="$2" ;;
        --tag) TAG="$2" ;;
        --pass) PASSWORD="$2" ;;
        --screen) SCREEN_NAME="$2" ;;
      esac
      shift 2
      ;;
    --restore-hugepages)
      RESTORE_HUGEPAGES=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# 不允许整个脚本或矿工以 root 运行；sudo 只用于短暂设置 huge pages。
if [[ "$(id -u)" -eq 0 ]]; then
  echo "请以普通用户运行 ./zx.sh；脚本只会为内核大页设置短暂调用 sudo，矿工不会以 root 运行。" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/xmrig"
SAFE_SCREEN_NAME="${SCREEN_NAME//[^A-Za-z0-9_.-]/_}"
STATE_FILE="${STATE_DIR}/${SAFE_SCREEN_NAME}.hugepages"

write_sysfs_value() {
  local value="$1" path="$2"
  sudo sh -c 'printf "%s\n" "$1" > "$2"' sh "$value" "$path"
}

screen_exists() {
  screen -S "$SCREEN_NAME" -Q select . >/dev/null 2>&1
}

# 如果之前通过本脚本增加了页池，只能在矿工/其他使用者释放大页后回滚。
if (( RESTORE_HUGEPAGES )); then
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "没有找到此 screen 会话的大页预留快照；未更改系统设置。"
    exit 0
  fi
  if command -v screen >/dev/null 2>&1 && screen_exists; then
    echo "screen 会话 '$SCREEN_NAME' 仍存在。请先停止它（screen -S '$SCREEN_NAME' -X quit），再运行 --restore-hugepages。" >&2
    exit 1
  fi
  if pgrep -u "$(id -u)" -x xmrig >/dev/null 2>&1; then
    echo "当前用户仍有 xmrig 进程；为避免回收正在使用的大页，未更改系统设置。" >&2
    exit 1
  fi
  mapfile -t SAVED_VALUES < "$STATE_FILE"
  ORIGINAL_HUGEPAGES="${SAVED_VALUES[0]:-}"
  if [[ ! "$ORIGINAL_HUGEPAGES" =~ ^[0-9]+$ ]]; then
    echo "大页快照文件无效：$STATE_FILE" >&2
    exit 1
  fi
  HP_TOTAL="$(awk '/^HugePages_Total:/ {print $2}' /proc/meminfo)"
  HP_FREE="$(awk '/^HugePages_Free:/ {print $2}' /proc/meminfo)"
  if [[ "$HP_TOTAL" != "$HP_FREE" ]]; then
    echo "仍有大页被占用（空闲 $HP_FREE / 总计 $HP_TOTAL）；请停止所有使用 huge pages 的进程后重试。" >&2
    exit 1
  fi
  echo "将通过 sudo 把 2 MiB huge pages 数量恢复为启动前的 $ORIGINAL_HUGEPAGES。"
  sudo -v
  write_sysfs_value "$ORIGINAL_HUGEPAGES" "$HUGEPAGES_SYSFS"
  sleep 1
  HP_NOW="$(cat "$HUGEPAGES_SYSFS")"
  if [[ "$HP_NOW" != "$ORIGINAL_HUGEPAGES" ]]; then
    echo "内核当前保留 $HP_NOW 页，尚未完全恢复；快照已保留，可稍后重试。" >&2
    exit 1
  fi
  rm -f "$STATE_FILE"
  echo "已恢复大页数量为 $HP_NOW；hugetlb_shm_group 未被持久更改。"
  exit 0
fi

# 未通过 --worker 指定时，每次启动生成一个随机 worker 名。
if [[ -z "$WORKER" ]]; then
  RANDOM_SUFFIX="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  WORKER="worker-${RANDOM_SUFFIX}"
fi

# 所有系统级改动都只是运行时值；组访问仅在 RandomX 初始化期间临时开放。
ORIGINAL_HUGEPAGES="$(cat "$HUGEPAGES_SYSFS")"
ORIGINAL_HUGETLB_GROUP="$(cat "$HUGETLB_GROUP_SYSFS")"
TARGET_GID="$(id -g)"
HUGEPAGES_CHANGED=0
GROUP_CHANGED=0
STATE_CREATED=0
INIT_LOG=""

restore_hugetlb_group() {
  if (( GROUP_CHANGED )); then
    if sudo -n sh -c 'printf "%s\n" "$1" > "$2"' sh "$ORIGINAL_HUGETLB_GROUP" "$HUGETLB_GROUP_SYSFS"; then
      GROUP_CHANGED=0
      echo "已恢复 hugetlb_shm_group=$ORIGINAL_HUGETLB_GROUP。"
    else
      echo "警告：未能自动恢复 hugetlb_shm_group；请手动恢复为 $ORIGINAL_HUGETLB_GROUP。" >&2
    fi
  fi
}

cleanup() {
  restore_hugetlb_group
  if [[ -n "$INIT_LOG" ]]; then rm -f "$INIT_LOG"; fi
  # 若 screen 未成功启动，撤销本次新增的页池，避免空闲的大页留在系统中。
  if (( HUGEPAGES_CHANGED )) && ! screen_exists; then
    if sudo -n sh -c 'printf "%s\n" "$1" > "$2"' sh "$ORIGINAL_HUGEPAGES" "$HUGEPAGES_SYSFS"; then
      if (( STATE_CREATED )); then rm -f "$STATE_FILE"; fi
      echo "矿工未启动，已撤销本次 huge pages 预留。" >&2
    else
      echo "警告：矿工未启动且大页无法自动回滚；可运行 ./zx.sh --restore-hugepages。" >&2
    fi
  fi
}
trap cleanup EXIT INT TERM

# 如果 2 MiB huge pages 不足，清楚说明 sudo 用途后只调整运行时页池，不写 sysctl 配置文件。
if (( ORIGINAL_HUGEPAGES < REQUIRED_HUGEPAGES )); then
  echo "将临时预留 ${REQUIRED_HUGEPAGES} 个 2 MiB huge pages（约 2.28 GiB）；需要 sudo。"
  echo "这不会写入开机配置；矿工仍以用户 $(id -un) 运行。"
  if ! command -v sudo >/dev/null 2>&1; then
    echo "找不到 sudo，无法安全预留大页；未启动矿工。" >&2
    exit 1
  fi
  sudo -v
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  if [[ ! -f "$STATE_FILE" ]]; then
    printf '%s\n' "$ORIGINAL_HUGEPAGES" > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
    STATE_CREATED=1
  else
    mapfile -t SAVED_VALUES < "$STATE_FILE"
    ORIGINAL_HUGEPAGES="${SAVED_VALUES[0]:-}"
    if [[ ! "$ORIGINAL_HUGEPAGES" =~ ^[0-9]+$ ]]; then
      echo "现有大页快照无效：$STATE_FILE" >&2
      exit 1
    fi
  fi
  write_sysfs_value "$REQUIRED_HUGEPAGES" "$HUGEPAGES_SYSFS"
  ACTUAL_HUGEPAGES="$(cat "$HUGEPAGES_SYSFS")"
  if (( ACTUAL_HUGEPAGES < REQUIRED_HUGEPAGES )); then
    echo "内核只预留了 $ACTUAL_HUGEPAGES / $REQUIRED_HUGEPAGES 页；回滚并停止启动。" >&2
    write_sysfs_value "$ORIGINAL_HUGEPAGES" "$HUGEPAGES_SYSFS"
    if (( STATE_CREATED )); then rm -f "$STATE_FILE"; STATE_CREATED=0; fi
    exit 1
  fi
  HUGEPAGES_CHANGED=1
fi

# 允许当前普通用户短暂映射 huge pages；等 RandomX READY 后立刻恢复原组值。
if [[ "$ORIGINAL_HUGETLB_GROUP" != "$TARGET_GID" ]]; then
  echo "初始化期间将临时把 hugetlb_shm_group 设为当前用户组 $TARGET_GID，启动就绪后立即恢复。"
  sudo -v
  write_sysfs_value "$TARGET_GID" "$HUGETLB_GROUP_SYSFS"
  GROUP_CHANGED=1
fi

echo "=== 一键 xmrig 安装并启动（临时 huge pages，普通用户运行） ==="
echo "配置:"
echo "  矿池:   $POOL"
echo "  币种:   $COIN"
echo "  钱包:   $WALLET"
echo "  Worker: $WORKER"
echo "  Tag:    $TAG"
echo "  线程:   $THREADS"
echo "  Screen: $SCREEN_NAME"
echo

cd "$SCRIPT_DIR"

# Step 1: 下载 xmrig
if [[ ! -f "$TARBALL" ]]; then
  echo "Step 1: 下载 xmrig..."
  wget --no-verbose "$URL" -O "$TARBALL"
else
  echo "Step 1: 已存在 $TARBALL，跳过下载。"
fi

# Step 2: 解压
if [[ ! -d "xmrig-${XMRIg_VERSION}" ]]; then
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
    echo "  无 sudo，无法安装 screen。" >&2
    exit 1
  fi
else
  echo "  已安装。"
fi

# Step 4: 准备目录
cd "xmrig-${XMRIg_VERSION}"
chmod +x xmrig
cd "$SCRIPT_DIR"

# Step 5: 启动 miner；%q 对每个参数单独转义，worker 不会继承 sudo。
printf -v CMD '%q ' ./xmrig -a rx -o "$POOL" -u "${COIN}:${WALLET}.${WORKER}#${TAG}" -p "$PASSWORD" -t "$THREADS"
if screen_exists; then
  echo "关闭已有同名 screen 会话 '$SCREEN_NAME'..."
  screen -S "$SCREEN_NAME" -X quit || true
  sleep 1
fi

echo "Step 5: 以 $(id -un) 启动 xmrig ..."
screen -dmS "$SCREEN_NAME" bash -lc "cd 'xmrig-${XMRIg_VERSION}' && exec ${CMD}"

# 等待初始化完成，随后立即还原临时 hugepage 组权限。
INIT_LOG="$(mktemp "/tmp/xmrig-${SAFE_SCREEN_NAME}.init.XXXXXX")"
READY=0
for _ in $(seq 1 120); do
  if ! screen_exists; then break; fi
  screen -S "$SCREEN_NAME" -X hardcopy -h "$INIT_LOG" >/dev/null 2>&1 || true
  if grep -q 'READY threads' "$INIT_LOG"; then READY=1; break; fi
  sleep 1
done

restore_hugetlb_group
if (( READY )); then
  if grep -Eq 'allocated .* huge pages 100%' "$INIT_LOG"; then
    echo "RandomX 数据集已验证为 100% huge pages。"
  else
    echo "警告：矿工已就绪，但日志未确认数据集达到 100% huge pages；请检查 screen 日志。" >&2
  fi
else
  echo "警告：120 秒内未检测到 READY 日志；请检查 screen '$SCREEN_NAME'，临时组权限已恢复。" >&2
fi

# 大页数量在矿工运行期间保持预留；停止 miner 后用 --restore-hugepages 恢复原数量。
if [[ -f "$STATE_FILE" ]]; then
  echo "停止该 screen 会话后运行：./zx.sh --restore-hugepages --screen '$SCREEN_NAME'"
fi
echo
echo "已启动 miner (screen 名称: $SCREEN_NAME, worker: $WORKER, 用户: $(id -un))"
echo "查看:   screen -r $SCREEN_NAME"
echo "后台:   Ctrl+A+D"
echo "退出:   screen -S $SCREEN_NAME -X quit"
