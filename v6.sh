#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "请用 root 运行"; exit 1; }

API_BASE="${DYNAMICV6_API_BASE:-https://billing.aethercloud.io/api/dynamicv6/vm}"
CLIENT_URL="${DYNAMICV6_CLIENT_URL:-https://billing.aethercloud.io/dynamicv6/client.sh}"
RESTORE_URL="${DYNAMICV6_RESTORE_URL:-https://billing.aethercloud.io/dynamicv6/restore.sh}"
TOTAL_STEPS=7
GENERATED_CMD_NAME="qh"
GENERATED_CMD_PATH="/usr/local/bin/${GENERATED_CMD_NAME}"
QH_CONFIG_DIR="/etc/qh"
QH_PRIORITY_FILE="${QH_CONFIG_DIR}/priority.list"
QH_PRIORITY_GUIDE_FILE="${QH_CONFIG_DIR}/priority.guide.done"
QH_AUTO_CONFIG_FILE="${QH_CONFIG_DIR}/auto.env"
QH_STATE_DIR="/var/lib/qh"
QH_LAST_PROBE_FILE="${QH_STATE_DIR}/last_probe.tsv"
QH_ROUTE_FIX_FILE="${QH_STATE_DIR}/route_fix.tsv"
QH_AUTO_SERVICE="/etc/systemd/system/qh-autoheal.service"
QH_AUTO_TIMER="/etc/systemd/system/qh-autoheal.timer"
QH_AUTO_CRON="/etc/cron.d/qh-autoheal"
QH_AUTO_INTERVAL_MINUTES="${QH_AUTO_INTERVAL_MINUTES:-2}"
QH_AUTO_ENABLE_DEFAULT="${QH_AUTO_ENABLE:-0}"

INTERACTIVE=0
ASSUME_YES=0
PLAIN=0
IFACE=""
CLIENT_SCRIPT=""
AUTO_SWITCH_ENABLED="$QH_AUTO_ENABLE_DEFAULT"
NATIVE_VIA_OVERRIDE=""
NATIVE_SRC_OVERRIDE=""

STYLE_RESET=""
STYLE_INFO=""
STYLE_SUCCESS=""
STYLE_WARN=""
STYLE_ERROR=""

PROBE_IPV6_TARGET="${QH_IPV6_PROBE_TARGET:-2606:4700:4700::1111}"
PROBE_PING_COUNT="${QH_IPV6_PROBE_COUNT:-2}"
PROBE_PING_TIMEOUT="${QH_IPV6_PROBE_TIMEOUT:-3}"
STYLE_STEP=""

if [[ -t 0 && -t 1 ]]; then
  INTERACTIVE=1
fi

CURL_BASE_ARGS=(
  --fail
  --silent
  --show-error
  --location
  --ipv4
  --connect-timeout 10
  --retry 2
  --retry-delay 1
)

cleanup() {
  if [[ -n "$CLIENT_SCRIPT" && -f "$CLIENT_SCRIPT" ]]; then
    rm -f "$CLIENT_SCRIPT"
  fi
}
trap cleanup EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "缺少命令: $1"; exit 1; }
}

normalize_region_code() {
  local raw="${1,,}"
  local normalized

  if [[ "$raw" =~ (^|[^a-z])(tw|my|vn|jp|hk|sg|us)($|[^a-z]) ]]; then
    echo "${BASH_REMATCH[2]}"
    return 0
  fi

  normalized="$(sed -E 's/^([a-z]+).*/\1/; t; d' <<<"$raw" || true)"
  if [[ -n "$normalized" ]]; then
    echo "$normalized"
  else
    echo "unknown"
  fi
}

region_label() {
  case "${1,,}" in
    tw) echo "TW/台湾" ;;
    my) echo "MY/马来西亚" ;;
    vn) echo "VN/越南" ;;
    jp) echo "JP/日本" ;;
    hk) echo "HK/香港" ;;
    sg) echo "SG/新加坡" ;;
    us) echo "US/美国" ;;
    *)  echo "${1^^}/未知地区" ;;
  esac
}

detect_iface() {
  local iface

  iface="$(ip -o route show to default 2>/dev/null | awk '{print $5; exit}' || true)"
  if [[ -n "$iface" ]]; then
    echo "${iface%%@*}"
    return 0
  fi

  iface="$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  if [[ -n "$iface" ]]; then
    echo "${iface%%@*}"
    return 0
  fi

  return 1
}

detect_vm_uuid() {
  if [[ -r /sys/class/dmi/id/product_uuid ]]; then
    tr '[:upper:]' '[:lower:]' < /sys/class/dmi/id/product_uuid | tr -d '[:space:]'
    return 0
  fi

  if command -v dmidecode >/dev/null 2>&1; then
    dmidecode -s system-uuid 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
    return 0
  fi

  return 1
}

is_utf8_locale() {
  local locale="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  locale="${locale^^}"
  [[ "$locale" == *UTF-8* || "$locale" == *UTF8* ]]
}

init_styles() {
  if (( PLAIN == 0 )) && [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; then
    STYLE_RESET=$'\033[0m'
    STYLE_INFO=$'\033[36m'
    STYLE_SUCCESS=$'\033[32m'
    STYLE_WARN=$'\033[33m'
    STYLE_ERROR=$'\033[31m'
    STYLE_STEP=$'\033[1;34m'
  fi
}

log() {
  local level="$1"
  shift

  local color prefix
  case "$level" in
    info)    color="$STYLE_INFO";    prefix="[INFO]" ;;
    success) color="$STYLE_SUCCESS"; prefix="[ OK ]" ;;
    warn)    color="$STYLE_WARN";    prefix="[WARN]" ;;
    error)   color="$STYLE_ERROR";   prefix="[ERR ]" ;;
    step)    color="$STYLE_STEP";    prefix="[STEP]" ;;
    *)       color="";               prefix="[....]" ;;
  esac

  printf '%b%s%b %s\n' "$color" "$prefix" "$STYLE_RESET" "$*"
}

step() {
  local index="$1"
  local title="$2"
  log step "[$index/$TOTAL_STEPS] $title"
}

print_kv() {
  printf '  %-16s %s\n' "$1" "$2"
}

repeat_char() {
  local char="$1"
  local count="$2"
  local out

  (( count > 0 )) || { printf '\n'; return 0; }
  printf -v out '%*s' "$count" ''
  printf '%s\n' "${out// /$char}"
}

panel_width() {
  local cols=92

  if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
    cols="$(tput cols 2>/dev/null || echo 92)"
  fi

  (( cols < 72 )) && cols=72
  (( cols > 112 )) && cols=112
  echo "$cols"
}

PANEL_WIDTH=92

panel_open() {
  local title="$1"
  PANEL_WIDTH="$(panel_width)"
  printf '+%s+\n' "$(repeat_char '-' "$((PANEL_WIDTH - 2))" | tr -d '\n')"
  panel_text "$title"
  printf '+%s+\n' "$(repeat_char '=' "$((PANEL_WIDTH - 2))" | tr -d '\n')"
}

panel_sep() {
  printf '+%s+\n' "$(repeat_char '-' "$((PANEL_WIDTH - 2))" | tr -d '\n')"
}

panel_text() {
  local width="$((PANEL_WIDTH - 4))"
  local line

  while IFS= read -r line; do
    printf '| %-*s |\n' "$width" "$line"
  done < <(printf '%s\n' "$*" | fold -s -w "$width")
}

panel_kv() {
  panel_text "$(printf '%-14s %s' "$1" "$2")"
}

panel_close() {
  printf '+%s+\n' "$(repeat_char '-' "$((PANEL_WIDTH - 2))" | tr -d '\n')"
}

section_title() {
  echo
  printf '=== %s ===\n' "$1"
}

section_note() {
  printf '%s\n' "$1"
}

status_line() {
  printf '%s: %s\n' "$1" "$2"
}

menu_line() {
  printf '%s. %s\n' "$1" "$2"
}

prompt_read() {
  local __var_name="$1"
  local __prompt="$2"
  local __answer=""
  local __tty_fd

  if [[ -t 0 ]]; then
    read -r -p "$__prompt" __answer || return 1
  elif exec {__tty_fd}<>/dev/tty 2>/dev/null; then
    printf '%s' "$__prompt" >&${__tty_fd}
    IFS= read -r __answer <&${__tty_fd} || {
      exec {__tty_fd}>&-
      return 1
    }
    exec {__tty_fd}>&-
  else
    return 1
  fi

  printf -v "$__var_name" '%s' "$__answer"
}

show_installer_banner() {
  section_title "QH DynamicV6 IPv6 切换工具"
  section_note "原生 IPv6 与 DynamicV6 多地区出口一键切换安装脚本。"
  section_note "支持手动切换、优先级自动切换、纯 IPv6 连通性检测与定时巡检。"
}

confirm() {
  local prompt="$1"
  local answer

  if (( ASSUME_YES == 1 || INTERACTIVE == 0 )); then
    return 0
  fi

  prompt_read answer "$prompt [Y/n]: " || return 1
  echo
  [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
}

usage() {
  cat <<'EOF'
用法:
  bash setup-switch-v6-from-dynamicv6.sh [网卡名]
  bash setup-switch-v6-from-dynamicv6.sh --iface eth0

可选参数:
  -i, --iface IFACE      指定网卡
      --native-via IPv6  手动指定原生 IPv6 网关
      --native-src IPv6  手动指定原生 IPv6 地址
  -y, --yes              跳过确认提示
      --non-interactive  非交互模式，自动使用检测到的默认网卡
      --plain            关闭彩色输出
  -h, --help             查看帮助
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      -i|--iface)
        [[ $# -ge 2 ]] || { log error "--iface 需要一个网卡名"; exit 1; }
        IFACE="$2"
        shift 2
        ;;
      --native-via)
        [[ $# -ge 2 ]] || { log error "--native-via 需要一个 IPv6 网关"; exit 1; }
        NATIVE_VIA_OVERRIDE="$2"
        shift 2
        ;;
      --native-src)
        [[ $# -ge 2 ]] || { log error "--native-src 需要一个 IPv6 地址"; exit 1; }
        NATIVE_SRC_OVERRIDE="$2"
        shift 2
        ;;
      -y|--yes|--assume-yes)
        ASSUME_YES=1
        shift
        ;;
      --non-interactive)
        INTERACTIVE=0
        ASSUME_YES=1
        shift
        ;;
      --plain)
        PLAIN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        log error "未知参数: $1"
        usage
        exit 1
        ;;
      *)
        if [[ -z "$IFACE" ]]; then
          IFACE="$1"
          shift
        else
          log error "多余参数: $1"
          usage
          exit 1
        fi
        ;;
    esac
  done

  if (($#)); then
    log error "存在未处理参数: $*"
    usage
    exit 1
  fi
}

route_field() {
  local line="$1"
  local key="$2"
  awk -v key="$key" '{for(i=1;i<=NF;i++) if($i==key){print $(i+1); exit}}' <<<"$line"
}

route_metric() {
  sed -n 's/.* metric \([0-9]\+\).*/\1/p' <<<"$1"
}

route_onlink() {
  grep -qw onlink <<<"$1" && echo "1" || echo "0"
}

pick_best_default_route() {
  local iface="${1:-}"

  if [[ -n "$iface" ]]; then
    ip -6 route show default dev "$iface"
  else
    ip -6 route show default
  fi | awk '
    {
      metric = 999999
      for (i = 1; i <= NF; i++) {
        if ($i == "metric") {
          metric = $(i + 1)
        }
      }
      if (best == "" || metric < best_metric) {
        best = $0
        best_metric = metric
      }
    }
    END {
      print best
    }
  '
}

strip_cidr() {
  echo "${1%/*}"
}

split_ipv6_hextets() {
  local addr="${1,,}"
  local left right part missing i
  local -a left_parts=() right_parts=() parts=()

  [[ -n "$addr" ]] || return 1

  if [[ "$addr" == *"::"* ]]; then
    left="${addr%%::*}"
    right="${addr#*::}"
    [[ "$addr" == ::* ]] && left=""
    [[ "$addr" == *:: ]] && right=""

    if [[ -n "$left" ]]; then
      IFS=':' read -r -a left_parts <<< "$left"
    fi
    if [[ -n "$right" ]]; then
      IFS=':' read -r -a right_parts <<< "$right"
    fi

    missing=$((8 - ${#left_parts[@]} - ${#right_parts[@]}))
    (( missing >= 0 )) || return 1
    parts=("${left_parts[@]}")
    for ((i = 0; i < missing; i++)); do
      parts+=("0")
    done
    parts+=("${right_parts[@]}")
  else
    IFS=':' read -r -a parts <<< "$addr"
  fi

  (( ${#parts[@]} == 8 )) || return 1
  for i in "${!parts[@]}"; do
    [[ -n "${parts[$i]}" ]] || parts[$i]="0"
    [[ "${parts[$i]}" =~ ^[0-9a-f]{1,4}$ ]] || return 1
    printf '%x\n' "0x${parts[$i]}"
  done
}

normalize_ipv6() {
  local addr="$1"
  local -a parts=()
  local out=""
  local i

  addr="$(strip_cidr "$addr")"
  mapfile -t parts < <(split_ipv6_hextets "$addr") || return 1
  (( ${#parts[@]} == 8 )) || return 1

  for i in "${!parts[@]}"; do
    out+="${parts[$i]}"
    [[ "$i" -lt 7 ]] && out+=":"
  done
  echo "$out"
}

normalize_cidr_key() {
  local cidr="$1"
  local addr prefix normalized

  [[ "$cidr" == */* ]] || return 1
  addr="${cidr%/*}"
  prefix="${cidr#*/}"
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1

  normalized="$(normalize_ipv6 "$addr" 2>/dev/null || true)"
  [[ -n "$normalized" ]] || return 1
  printf '%s/%s\n' "$normalized" "$prefix"
}

ipv6_prefix_key() {
  local addr="$1"
  local prefix_len="$2"
  local -a parts=()
  local keep i out=""

  [[ "$prefix_len" =~ ^[0-9]+$ ]] || return 1
  (( prefix_len >= 0 && prefix_len <= 128 && prefix_len % 16 == 0 )) || return 1

  mapfile -t parts < <(split_ipv6_hextets "$addr") || return 1
  (( ${#parts[@]} == 8 )) || return 1

  keep=$((prefix_len / 16))
  for ((i = 0; i < keep; i++)); do
    out+="${parts[$i]}"
    [[ "$i" -lt $((keep - 1)) ]] && out+=":"
  done

  echo "$out"
}

ipv6_in_prefix() {
  local addr="$1"
  local prefix="$2"
  local prefix_addr prefix_len addr_key prefix_key

  [[ -n "$addr" && "$prefix" == */* ]] || return 1
  prefix_addr="${prefix%/*}"
  prefix_len="${prefix#*/}"

  addr_key="$(ipv6_prefix_key "$addr" "$prefix_len" 2>/dev/null || true)"
  prefix_key="$(ipv6_prefix_key "$prefix_addr" "$prefix_len" 2>/dev/null || true)"
  [[ -n "$addr_key" && -n "$prefix_key" && "$addr_key" == "$prefix_key" ]]
}

ipv6_equal() {
  local left right

  left="$(normalize_ipv6 "${1:-}" 2>/dev/null || true)"
  right="$(normalize_ipv6 "${2:-}" 2>/dev/null || true)"
  [[ -n "$left" && -n "$right" && "$left" == "$right" ]]
}

iface_primary_native_cidr() {
  local iface="$1"

  ip -6 -o addr show dev "$iface" scope global 2>/dev/null | awk '$4 !~ /\/128$/ { print $4; exit }'
}

iface_primary_native_addr() {
  local iface="$1"
  local cidr

  cidr="$(iface_primary_native_cidr "$iface" || true)"
  [[ -n "$cidr" ]] || return 1
  strip_cidr "$cidr"
}

pick_default_route_for_src() {
  local iface="$1"
  local want_src="$2"

  [[ -n "$want_src" ]] || return 1

  ip -6 route show default dev "$iface" 2>/dev/null | awk -v want_src="$want_src" '
    {
      metric = 999999
      src = ""
      for (i = 1; i <= NF; i++) {
        if ($i == "metric") {
          metric = $(i + 1)
        } else if ($i == "src") {
          src = $(i + 1)
        }
      }
      if (src == want_src && (best == "" || metric < best_metric)) {
        best = $0
        best_metric = metric
      }
    }
    END {
      print best
    }
  '
}

route_get_for_src() {
  local iface="$1"
  local want_src="$2"
  local probe_target="${3:-$PROBE_IPV6_TARGET}"

  [[ -n "$want_src" && -n "$probe_target" ]] || return 1

  ip -6 route get "$probe_target" from "$want_src" oif "$iface" 2>/dev/null | awk 'NR == 1 { print; exit }'
}

native_gateway_guess_from_cidr() {
  local cidr="$1"
  local addr prefix i
  local -a parts=()

  [[ -n "$cidr" ]] || return 1
  addr="${cidr%/*}"
  prefix="${cidr#*/}"
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  (( prefix > 0 && prefix < 128 && prefix % 16 == 0 )) || return 1

  mapfile -t parts < <(split_ipv6_hextets "$addr") || return 1
  (( ${#parts[@]} == 8 )) || return 1

  for ((i = prefix / 16; i < 8; i++)); do
    parts[$i]="0"
  done
  parts[7]="1"
  printf '%s:%s:%s:%s:%s:%s:%s:%s\n' \
    "${parts[0]}" "${parts[1]}" "${parts[2]}" "${parts[3]}" \
    "${parts[4]}" "${parts[5]}" "${parts[6]}" "${parts[7]}"
}

dynamic_gateway_guess_from_prefix() {
  local prefix="$1"
  local addr prefix_len i
  local -a parts=()

  [[ "$prefix" == */* ]] || return 1
  addr="${prefix%/*}"
  prefix_len="${prefix#*/}"
  [[ "$prefix_len" =~ ^[0-9]+$ ]] || return 1
  (( prefix_len == 80 )) || return 1

  mapfile -t parts < <(split_ipv6_hextets "$addr") || return 1
  (( ${#parts[@]} == 8 )) || return 1

  for ((i = prefix_len / 16; i < 8; i++)); do
    parts[$i]="0"
  done
  parts[7]="3"
  printf '%s:%s:%s:%s:%s:%s:%s:%s\n' \
    "${parts[0]}" "${parts[1]}" "${parts[2]}" "${parts[3]}" \
    "${parts[4]}" "${parts[5]}" "${parts[6]}" "${parts[7]}"
}

route_gateway_for_dynamic_cidr() {
  local cidr="$1"
  local prefix="${2:-}"
  local iface="${3:-$IFACE}"
  local probe_prefix line gw dest

  [[ -n "$cidr" && -n "$iface" ]] || return 1
  if [[ "$prefix" == */* ]]; then
    probe_prefix="$prefix"
  else
    probe_prefix="${cidr%/*}/80"
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    gw="$(route_field "$line" "via")"
    [[ -n "$gw" ]] || continue
    if ipv6_in_prefix "$gw" "$probe_prefix"; then
      echo "$gw"
      return 0
    fi
  done < <(ip -6 route show default dev "$iface" 2>/dev/null)

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    dest="${line%% *}"
    [[ "$dest" == */128 ]] || continue
    gw="${dest%/128}"
    if ipv6_in_prefix "$gw" "$probe_prefix"; then
      echo "$gw"
      return 0
    fi
  done < <(ip -6 route show dev "$iface" 2>/dev/null)

  return 1
}

load_existing_native_hint() {
  local expected_src="$1"
  local line key value

  EXISTING_NATIVE_VIA=""
  EXISTING_NATIVE_SRC=""
  EXISTING_NATIVE_METRIC=""
  EXISTING_NATIVE_ONLINK=""

  [[ -n "$expected_src" ]] || return 0
  [[ -f "$GENERATED_CMD_PATH" ]] || return 0

  while IFS= read -r line; do
    case "$line" in
      NATIVE_VIA=*)
        EXISTING_NATIVE_VIA="${line#NATIVE_VIA=}"
        ;;
      NATIVE_SRC=*)
        EXISTING_NATIVE_SRC="${line#NATIVE_SRC=}"
        ;;
      NATIVE_METRIC=*)
        EXISTING_NATIVE_METRIC="${line#NATIVE_METRIC=}"
        ;;
      NATIVE_ONLINK=*)
        EXISTING_NATIVE_ONLINK="${line#NATIVE_ONLINK=}"
        ;;
    esac
  done < "$GENERATED_CMD_PATH"

  if [[ -n "$EXISTING_NATIVE_SRC" ]] && ! ipv6_equal "$EXISTING_NATIVE_SRC" "$expected_src"; then
    EXISTING_NATIVE_VIA=""
    EXISTING_NATIVE_SRC=""
    EXISTING_NATIVE_METRIC=""
    EXISTING_NATIVE_ONLINK=""
  fi
}

prompt_native_gateway() {
  local candidate_src="$1"
  local current_line="$2"
  local default_hint="$3"
  local answer prompt

  if [[ -n "$NATIVE_VIA_OVERRIDE" ]]; then
    native_via="$NATIVE_VIA_OVERRIDE"
    native_src="${NATIVE_SRC_OVERRIDE:-$candidate_src}"
    log warn "已使用手动指定的原生 IPv6 网关: $native_via"
    return 0
  fi

  if (( INTERACTIVE == 0 || ASSUME_YES == 1 )); then
    log error "检测到当前默认路由很可能已切到 DynamicV6，无法安全识别原生 IPv6 网关；请先切回原生线路后重试，或使用 --native-via 手动指定"
    [[ -n "$candidate_src" ]] && log error "当前识别到的原生 IPv6 地址候选: $candidate_src"
    return 1
  fi

  section_title "原生 IPv6 识别确认"
  section_note "检测到网卡上存在原生全局 IPv6 地址，但当前默认路由并未使用它。"
  section_note "这通常表示系统当前还停留在 DynamicV6 切换后的状态。"
  [[ -n "$candidate_src" ]] && print_kv "原生地址候选" "$candidate_src"
  [[ -n "$current_line" ]] && print_kv "当前默认路由" "$current_line"
  [[ -n "$default_hint" ]] && section_note "已找到上一版脚本保存的原生网关，直接回车即可使用该值。"

  prompt="请输入原生 IPv6 网关"
  [[ -n "$default_hint" ]] && prompt+=" [$default_hint]"
  prompt+=": "

  while true; do
    prompt_read answer "$prompt" || return 1
    echo
    answer="${answer:-$default_hint}"
    if [[ -n "$answer" && "$answer" == *:* ]]; then
      native_via="$answer"
      native_src="${NATIVE_SRC_OVERRIDE:-$candidate_src}"
      log warn "当前环境未处于原生默认路由，已按你提供的网关记录原生 IPv6 出口"
      return 0
    fi
    log warn "请输入有效的 IPv6 网关地址，或先恢复原生线路后重试"
  done
}

detect_native_profile() {
  local iface="$1"
  local current_line current_src current_via candidate_src candidate_cidr matched_line route_get_line route_get_via guessed_native_via

  current_line="$(pick_best_default_route "$iface" || true)"
  native_metric="$(route_metric "$current_line")"
  native_onlink="$(route_onlink "$current_line")"
  [[ -n "$native_metric" ]] || native_metric="1024"
  [[ -n "$native_onlink" ]] || native_onlink="0"

  candidate_cidr="$(iface_primary_native_cidr "$iface" || true)"

  if [[ -n "$NATIVE_SRC_OVERRIDE" ]]; then
    candidate_src="$NATIVE_SRC_OVERRIDE"
  else
    candidate_src="$(strip_cidr "$candidate_cidr")"
  fi

  current_src="$(route_field "$current_line" "src")"
  current_via="$(route_field "$current_line" "via")"
  if [[ -z "$candidate_src" ]]; then
    candidate_src="$current_src"
  fi

  [[ -n "$candidate_src" ]] || {
    log error "无法识别 $iface 上的原生 IPv6 地址；请先确认原生 IPv6 已配置，或使用 --native-src 手动指定"
    return 1
  }

  native_src="$candidate_src"

  if [[ -n "$NATIVE_VIA_OVERRIDE" ]]; then
    native_via="$NATIVE_VIA_OVERRIDE"
    return 0
  fi

  if [[ -n "$current_line" && -n "$current_src" ]] && ipv6_equal "$current_src" "$candidate_src"; then
    native_via="$(route_field "$current_line" "via")"
    [[ -n "$native_via" ]] || {
      log error "已识别原生 IPv6 地址 $candidate_src，但当前默认路由中缺少网关"
      return 1
    }
    return 0
  fi

  matched_line="$(pick_default_route_for_src "$iface" "$candidate_src" || true)"
  if [[ -n "$matched_line" ]]; then
    native_via="$(route_field "$matched_line" "via")"
    native_metric="$(route_metric "$matched_line")"
    native_onlink="$(route_onlink "$matched_line")"
    [[ -n "$native_metric" ]] || native_metric="1024"
    [[ -n "$native_onlink" ]] || native_onlink="0"
    return 0
  fi

  route_get_line="$(route_get_for_src "$iface" "$candidate_src" || true)"
  route_get_via="$(route_field "$route_get_line" "via")"
  if [[ -n "$route_get_via" ]]; then
    native_via="$route_get_via"
    if [[ -n "$current_via" ]] && ipv6_equal "$current_via" "$route_get_via"; then
      log warn "当前默认路由缺少原生源地址标记，已通过内核路由推导确认原生 IPv6 网关"
    else
      log warn "当前默认路由疑似仍在 DynamicV6 线路上，已通过内核路由推导确认原生 IPv6 网关"
    fi
    return 0
  fi

  load_existing_native_hint "$candidate_src"
  if [[ -n "$EXISTING_NATIVE_VIA" ]]; then
    native_via="$EXISTING_NATIVE_VIA"
    [[ -n "$EXISTING_NATIVE_METRIC" ]] && native_metric="$EXISTING_NATIVE_METRIC"
    [[ -n "$EXISTING_NATIVE_ONLINK" ]] && native_onlink="$EXISTING_NATIVE_ONLINK"
    log warn "当前默认路由疑似仍在 DynamicV6 线路上，已改用旧配置中保存的原生 IPv6 网关"
    return 0
  fi

  guessed_native_via="$(native_gateway_guess_from_cidr "$candidate_cidr" || true)"
  if [[ -n "$guessed_native_via" ]]; then
    native_via="$guessed_native_via"
    log warn "当前默认路由疑似仍在 DynamicV6 线路上，已根据原生地址前缀自动推断原生 IPv6 网关"
    return 0
  fi

  prompt_native_gateway "$candidate_src" "$current_line" "$EXISTING_NATIVE_VIA"
}

list_candidate_ifaces() {
  ip -o link show | awk -F': ' '{print $2}' | awk -F'@' '$1 != "lo" && !seen[$1]++ {print $1}'
}

iface_state() {
  if ip -o link show dev "$1" 2>/dev/null | grep -q '<[^>]*UP[^>]*>'; then
    echo "UP"
  else
    echo "DOWN"
  fi
}

iface_primary_addr() {
  local iface="$1"
  local family="$2"

  if [[ "$family" == "4" ]]; then
    ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4; exit}'
  else
    ip -6 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4; exit}'
  fi
}

print_iface_choices() {
  local default_iface="$1"
  local i iface state v4 v6 marker

  section_title "Interface Selection"
  section_note "Multiple interfaces detected. Choose the interface used for DynamicV6."
  for i in "${!CANDIDATE_IFACES[@]}"; do
    iface="${CANDIDATE_IFACES[$i]}"
    state="$(iface_state "$iface")"
    v4="$(iface_primary_addr "$iface" 4)"
    v6="$(iface_primary_addr "$iface" 6)"
    [[ -n "$v4" ]] || v4="-"
    [[ -n "$v6" ]] || v6="-"
    marker=""
    [[ "$iface" == "$default_iface" ]] && marker=" [default]"
    printf '%s. %s%s\n' "$((i + 1))" "$iface" "$marker"
    printf '   状态: %s\n' "$state"
    printf '   IPv4: %s\n' "$v4"
    printf '   IPv6: %s\n' "$v6"
  done
}

select_iface() {
  local default_iface choice i

  if [[ -n "$IFACE" ]]; then
    ip link show dev "$IFACE" >/dev/null 2>&1 || { log error "网卡不存在: $IFACE"; exit 1; }
    return 0
  fi

  mapfile -t CANDIDATE_IFACES < <(list_candidate_ifaces)
  (( ${#CANDIDATE_IFACES[@]} > 0 )) || { log error "No usable network interface found"; exit 1; }

  default_iface="$(detect_iface || true)"

  if (( ${#CANDIDATE_IFACES[@]} == 1 )); then
    IFACE="${CANDIDATE_IFACES[0]}"
    log info "仅检测到一个可用网卡，自动使用: $IFACE"
    return 0
  fi

  if (( INTERACTIVE == 0 )); then
    [[ -n "$default_iface" ]] || { log error "非交互模式下无法自动识别默认网卡，请使用 --iface 指定"; exit 1; }
    IFACE="$default_iface"
    log info "非交互模式，自动使用默认网卡: $IFACE"
    return 0
  fi

  print_iface_choices "$default_iface"

  local default_choice="1"
  for i in "${!CANDIDATE_IFACES[@]}"; do
    if [[ "${CANDIDATE_IFACES[$i]}" == "$default_iface" ]]; then
      default_choice="$((i + 1))"
      break
    fi
  done

  while true; do
    prompt_read choice "请选择网卡 [$default_choice]: " || { log error "无法从终端读取网卡选择"; exit 1; }
    choice="${choice:-$default_choice}"

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#CANDIDATE_IFACES[@]} )); then
      IFACE="${CANDIDATE_IFACES[$((choice - 1))]}"
      break
    fi

    for i in "${!CANDIDATE_IFACES[@]}"; do
      if [[ "${CANDIDATE_IFACES[$i]}" == "$choice" ]]; then
        IFACE="$choice"
        break
      fi
    done

    [[ -n "$IFACE" ]] && break
    log warn "输入无效，请输入序号或网卡名"
  done
}

download_client_script() {
  CLIENT_SCRIPT="$(mktemp /tmp/dynamicv6-client.XXXXXX.sh)"
  if ! curl "${CURL_BASE_ARGS[@]}" --output "$CLIENT_SCRIPT" "$CLIENT_URL"; then
    log error "下载 DynamicV6 分发脚本失败: $CLIENT_URL"
    exit 1
  fi
  chmod +x "$CLIENT_SCRIPT"
}

emit_scalar() {
  local name="$1"
  local value="$2"
  printf '%s=%q\n' "$name" "$value"
}

emit_array() {
  local name="$1"
  shift

  printf '%s=(\n' "$name"
  local item
  for item in "$@"; do
    printf '  %q\n' "$item"
  done
  printf ')\n\n'
}

sync_priority_file() {
  local tmp line selector
  local -a desired ordered
  local -A valid seen

  mkdir -p "$QH_CONFIG_DIR" "$QH_STATE_DIR"

  desired=("${SELECTORS[@]}" "native")
  for selector in "${desired[@]}"; do
    valid["$selector"]=1
  done

  if [[ -f "$QH_PRIORITY_FILE" ]]; then
    while IFS= read -r line; do
      line="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$line")"
      [[ -n "$line" ]] || continue
      [[ -n "${valid[$line]:-}" ]] || continue
      [[ -z "${seen[$line]:-}" ]] || continue
      ordered+=("$line")
      seen["$line"]=1
    done < "$QH_PRIORITY_FILE"
  fi

  for selector in "${desired[@]}"; do
    if [[ -z "${seen[$selector]:-}" ]]; then
      ordered+=("$selector")
      seen["$selector"]=1
    fi
  done

  tmp="$(mktemp "${QH_CONFIG_DIR}/priority.XXXXXX")"
  printf '%s\n' "${ordered[@]}" > "$tmp"
  mv "$tmp" "$QH_PRIORITY_FILE"
  chmod 600 "$QH_PRIORITY_FILE"
}

write_auto_config() {
  mkdir -p "$QH_CONFIG_DIR" "$QH_STATE_DIR"
  cat > "$QH_AUTO_CONFIG_FILE" <<EOF
AUTO_SWITCH_ENABLED=${AUTO_SWITCH_ENABLED}
AUTO_INTERVAL_MINUTES=${QH_AUTO_INTERVAL_MINUTES}
EOF
  chmod 600 "$QH_AUTO_CONFIG_FILE"
}

normalize_auto_interval() {
  local value="${1:-}"

  if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 )); then
    echo "$value"
    return 0
  fi

  return 1
}

install_auto_scheduler() {
  local interval="$QH_AUTO_INTERVAL_MINUTES"

  mkdir -p "$QH_CONFIG_DIR" "$QH_STATE_DIR"
  mkdir -p "$(dirname "$QH_AUTO_SERVICE")" "$(dirname "$QH_AUTO_TIMER")" "$(dirname "$QH_AUTO_CRON")"

  if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
    interval=2
  elif (( interval < 1 )); then
    interval=2
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if [[ -d /run/systemd/system ]]; then
      cat > "$QH_AUTO_SERVICE" <<EOF
[Unit]
Description=QH IPv6 auto failover
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${GENERATED_CMD_PATH} --scheduled auto
EOF

      cat > "$QH_AUTO_TIMER" <<EOF
[Unit]
Description=Run QH IPv6 auto failover periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=${interval}min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

      rm -f "$QH_AUTO_CRON"
      systemctl daemon-reload
      systemctl enable --now qh-autoheal.timer >/dev/null 2>&1
    log info "已安装 systemd 定时器 qh-autoheal.timer，执行间隔为 ${interval} 分钟"
    return 0
  fi
  fi

  if (( interval > 59 )); then
    interval=2
    QH_AUTO_INTERVAL_MINUTES="$interval"
    log warn "当前环境未启用 systemd，cron 模式仅支持 1 到 59 分钟；巡检间隔已回退为 2 分钟"
  fi

cat > "$QH_AUTO_CRON" <<EOF
*/${interval} * * * * root ${GENERATED_CMD_PATH} --scheduled auto >/dev/null 2>&1
EOF
  chmod 644 "$QH_AUTO_CRON"
  log info "已安装 cron 任务 ${QH_AUTO_CRON}，执行间隔为 ${interval} 分钟"
  return 0
}

write_switch_script() {
  mkdir -p "$(dirname "$GENERATED_CMD_PATH")"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n\n'

    emit_scalar "IFACE" "$IFACE"
    emit_scalar "NATIVE_VIA" "$native_via"
    emit_scalar "NATIVE_SRC" "${native_src:-}"
    emit_scalar "NATIVE_METRIC" "$native_metric"
    emit_scalar "NATIVE_ONLINK" "$native_onlink"
    emit_scalar "CMD_PATH" "$GENERATED_CMD_PATH"
    emit_scalar "CONFIG_DIR" "$QH_CONFIG_DIR"
    emit_scalar "PRIORITY_FILE" "$QH_PRIORITY_FILE"
    emit_scalar "PRIORITY_GUIDE_FILE" "$QH_PRIORITY_GUIDE_FILE"
    emit_scalar "AUTO_CONFIG_FILE" "$QH_AUTO_CONFIG_FILE"
    emit_scalar "STATE_DIR" "$QH_STATE_DIR"
    emit_scalar "LAST_PROBE_FILE" "$QH_LAST_PROBE_FILE"
    emit_scalar "ROUTE_FIX_FILE" "$QH_ROUTE_FIX_FILE"
    emit_scalar "AUTO_SERVICE" "$QH_AUTO_SERVICE"
    emit_scalar "AUTO_TIMER" "$QH_AUTO_TIMER"
    emit_scalar "AUTO_CRON" "$QH_AUTO_CRON"
    emit_scalar "RESTORE_URL" "$RESTORE_URL"
    emit_scalar "AUTO_INTERVAL_MINUTES_DEFAULT" "$QH_AUTO_INTERVAL_MINUTES"
    printf '\n'

    emit_array "IPS" "${IPS[@]}"
    emit_array "GWS" "${GWS[@]}"
    emit_array "CODES" "${CODES[@]}"
    emit_array "REGIONS" "${REGIONS[@]}"
    emit_array "SELECTORS" "${SELECTORS[@]}"
    emit_array "DEFAULT_PRIORITY_SELECTORS" "${SELECTORS[@]}" "native"

    cat <<'SWITCHV6EOF'
PLAIN=0
QUIET=0
INTERACTIVE=0
SCHEDULED=0
if [[ -t 0 && -t 1 ]]; then
  INTERACTIVE=1
fi

STYLE_RESET=""
STYLE_INFO=""
STYLE_SUCCESS=""
STYLE_WARN=""
STYLE_ERROR=""

PROBE_IPV6_TARGET="${QH_IPV6_PROBE_TARGET:-2606:4700:4700::1111}"
PROBE_PING_COUNT="${QH_IPV6_PROBE_COUNT:-2}"
PROBE_PING_TIMEOUT="${QH_IPV6_PROBE_TIMEOUT:-3}"
PROBE_HTTP_URL="${QH_IPV6_HTTP_PROBE_URL:-https://ipv6.icanhazip.com}"
PROBE_HTTP_TIMEOUT="${QH_IPV6_HTTP_TIMEOUT:-8}"
PROBE_HTTP_MAX_TIME="${QH_IPV6_HTTP_MAX_TIME:-15}"
PROBE_MTU_SAFE_PAYLOAD="${QH_IPV6_MTU_SAFE_PAYLOAD:-1232}"
PROBE_MTU_LARGE_PAYLOAD="${QH_IPV6_MTU_LARGE_PAYLOAD:-1360}"
DEFAULT_REPAIR_MTU="${QH_IPV6_REPAIR_MTU:-1280}"
AUTO_SWITCH_ENABLED="0"
AUTO_INTERVAL_MINUTES="$AUTO_INTERVAL_MINUTES_DEFAULT"

PRIORITY_ORDER=()
LAST_SCAN_SELECTORS=()
LAST_SCAN_RESULTS=()

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "缺少命令: $1"; exit 1; }
}

init_styles() {
  if (( PLAIN == 0 )) && [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; then
    STYLE_RESET=$'\033[0m'
    STYLE_INFO=$'\033[36m'
    STYLE_SUCCESS=$'\033[32m'
    STYLE_WARN=$'\033[33m'
    STYLE_ERROR=$'\033[31m'
  fi
}

log() {
  local level="$1"
  shift

  (( QUIET == 0 )) || return 0

  local color prefix
  case "$level" in
    info)    color="$STYLE_INFO";    prefix="[INFO]" ;;
    success) color="$STYLE_SUCCESS"; prefix="[ OK ]" ;;
    warn)    color="$STYLE_WARN";    prefix="[WARN]" ;;
    error)   color="$STYLE_ERROR";   prefix="[ERR ]" ;;
    *)       color="";               prefix="[....]" ;;
  esac

  printf '%b%s%b %s\n' "$color" "$prefix" "$STYLE_RESET" "$*"
}

print_kv() {
  (( QUIET == 0 )) || return 0
  printf '  %-16s %s\n' "$1" "$2"
}

repeat_char() {
  local char="$1"
  local count="$2"
  local out

  (( count > 0 )) || { printf '\n'; return 0; }
  printf -v out '%*s' "$count" ''
  printf '%s\n' "${out// /$char}"
}

panel_width() {
  local cols=92

  if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
    cols="$(tput cols 2>/dev/null || echo 92)"
  fi

  (( cols < 72 )) && cols=72
  (( cols > 112 )) && cols=112
  echo "$cols"
}

PANEL_WIDTH=92

panel_open() {
  local title="$1"
  (( QUIET == 0 )) || return 0
  PANEL_WIDTH="$(panel_width)"
  printf '+%s+\n' "$(repeat_char '-' "$((PANEL_WIDTH - 2))" | tr -d '\n')"
  panel_text "$title"
  printf '+%s+\n' "$(repeat_char '=' "$((PANEL_WIDTH - 2))" | tr -d '\n')"
}

panel_sep() {
  (( QUIET == 0 )) || return 0
  printf '+%s+\n' "$(repeat_char '-' "$((PANEL_WIDTH - 2))" | tr -d '\n')"
}

panel_text() {
  (( QUIET == 0 )) || return 0
  local width="$((PANEL_WIDTH - 4))"
  local line

  while IFS= read -r line; do
    printf '| %-*s |\n' "$width" "$line"
  done < <(printf '%s\n' "$*" | fold -s -w "$width")
}

panel_kv() {
  (( QUIET == 0 )) || return 0
  panel_text "$(printf '%-14s %s' "$1" "$2")"
}

panel_close() {
  (( QUIET == 0 )) || return 0
  printf '+%s+\n' "$(repeat_char '-' "$((PANEL_WIDTH - 2))" | tr -d '\n')"
}

section_title() {
  (( QUIET == 0 )) || return 0
  echo
  printf '=== %s ===\n' "$1"
}

section_note() {
  (( QUIET == 0 )) || return 0
  printf '%s\n' "$1"
}

status_line() {
  (( QUIET == 0 )) || return 0
  printf '%s: %s\n' "$1" "$2"
}

menu_line() {
  (( QUIET == 0 )) || return 0
  printf '%s. %s\n' "$1" "$2"
}

prompt_read() {
  local __var_name="$1"
  local __prompt="$2"
  local __answer=""
  local __tty_fd

  if [[ -t 0 ]]; then
    read -r -p "$__prompt" __answer || return 1
  elif exec {__tty_fd}<>/dev/tty 2>/dev/null; then
    printf '%s' "$__prompt" >&${__tty_fd}
    IFS= read -r __answer <&${__tty_fd} || {
      exec {__tty_fd}>&-
      return 1
    }
    exec {__tty_fd}>&-
  else
    return 1
  fi

  printf -v "$__var_name" '%s' "$__answer"
}

route_field() {
  local line="$1"
  local key="$2"
  awk -v key="$key" '{for(i=1;i<=NF;i++) if($i==key){print $(i+1); exit}}' <<<"$line"
}

route_metric() {
  sed -n 's/.* metric \([0-9]\+\).*/\1/p' <<<"$1"
}

route_onlink() {
  grep -qw onlink <<<"$1" && echo "1" || echo "0"
}

route_mtu() {
  sed -n 's/.* mtu \([0-9]\+\).*/\1/p' <<<"$1"
}

strip_cidr() {
  echo "${1%/*}"
}

split_ipv6_hextets() {
  local addr="${1,,}"
  local left right missing i
  local -a left_parts=() right_parts=() parts=()

  [[ -n "$addr" ]] || return 1

  if [[ "$addr" == *"::"* ]]; then
    left="${addr%%::*}"
    right="${addr#*::}"
    [[ "$addr" == ::* ]] && left=""
    [[ "$addr" == *:: ]] && right=""

    if [[ -n "$left" ]]; then
      IFS=':' read -r -a left_parts <<< "$left"
    fi
    if [[ -n "$right" ]]; then
      IFS=':' read -r -a right_parts <<< "$right"
    fi

    missing=$((8 - ${#left_parts[@]} - ${#right_parts[@]}))
    (( missing >= 0 )) || return 1
    parts=("${left_parts[@]}")
    for ((i = 0; i < missing; i++)); do
      parts+=("0")
    done
    parts+=("${right_parts[@]}")
  else
    IFS=':' read -r -a parts <<< "$addr"
  fi

  (( ${#parts[@]} == 8 )) || return 1
  for i in "${!parts[@]}"; do
    [[ -n "${parts[$i]}" ]] || parts[$i]="0"
    [[ "${parts[$i]}" =~ ^[0-9a-f]{1,4}$ ]] || return 1
    printf '%x\n' "0x${parts[$i]}"
  done
}

normalize_ipv6() {
  local addr="$1"
  local -a parts=()
  local out=""
  local i

  addr="$(strip_cidr "$addr")"
  mapfile -t parts < <(split_ipv6_hextets "$addr") || return 1
  (( ${#parts[@]} == 8 )) || return 1

  for i in "${!parts[@]}"; do
    out+="${parts[$i]}"
    [[ "$i" -lt 7 ]] && out+=":"
  done
  echo "$out"
}

ipv6_equal() {
  local left right

  left="$(normalize_ipv6 "${1:-}" 2>/dev/null || true)"
  right="$(normalize_ipv6 "${2:-}" 2>/dev/null || true)"
  [[ -n "$left" && -n "$right" && "$left" == "$right" ]]
}

pick_best_default_route() {
  local iface="${1:-}"

  if [[ -n "$iface" ]]; then
    ip -6 route show default dev "$iface"
  else
    ip -6 route show default
  fi | awk '
    {
      metric = 999999
      for (i = 1; i <= NF; i++) {
        if ($i == "metric") {
          metric = $(i + 1)
        }
      }
      if (best == "" || metric < best_metric) {
        best = $0
        best_metric = metric
      }
    }
    END {
      print best
    }
  '
}

clear_defaults() {
  local line via metric

  while read -r line; do
    [[ -n "$line" ]] || continue
    via="$(route_field "$line" "via")"
    metric="$(route_metric "$line")"
    if [[ -n "$via" && -n "$metric" ]]; then
      ip -6 route del default via "$via" dev "$IFACE" metric "$metric" 2>/dev/null || true
    elif [[ -n "$via" ]]; then
      ip -6 route del default via "$via" dev "$IFACE" 2>/dev/null || true
    fi
  done < <(ip -6 route show default dev "$IFACE")
}

clear_gateway_routes() {
  local gw
  for gw in "${GWS[@]}"; do
    [[ "${gw,,}" == fe80:* ]] && continue
    ip -6 route del "${gw}/128" dev "$IFACE" 2>/dev/null || true
  done
  [[ "${NATIVE_VIA,,}" == fe80:* ]] || ip -6 route del "${NATIVE_VIA}/128" dev "$IFACE" 2>/dev/null || true
}

is_known_dynamic_gateway() {
  local want="$1"
  local gw
  for gw in "${GWS[@]}"; do
    if [[ "$gw" == "$want" ]]; then
      return 0
    fi
  done
  return 1
}

ensure_gateway_route() {
  local gw="$1"
  [[ "${gw,,}" == fe80:* ]] && return 0
  ip -6 route replace "${gw}/128" dev "$IFACE" metric 1023 onlink
}

replace_default_route() {
  local via="$1"
  local src="$2"
  local metric="$3"
  local onlink="$4"
  local mtu="${5:-}"

  local cmd=(ip -6 route replace default via "$via" dev "$IFACE")
  [[ -n "$src" ]] && cmd+=(src "$src")
  [[ -n "$metric" ]] && cmd+=(metric "$metric")
  [[ "$onlink" == "1" ]] && cmd+=(onlink)
  [[ -n "$mtu" ]] && cmd+=(mtu "$mtu")
  "${cmd[@]}"
}

restore_default_from_line() {
  local line="$1"
  local via src metric onlink mtu

  via="$(route_field "$line" "via")"
  src="$(route_field "$line" "src")"
  metric="$(route_metric "$line")"
  onlink="$(route_onlink "$line")"
  mtu="$(route_mtu "$line")"

  [[ -n "$via" ]] || return 1
  [[ -n "$metric" ]] || metric="1024"

  ensure_gateway_route "$via"

  replace_default_route "$via" "$src" "$metric" "$onlink" "$mtu"
}

restore_previous_route_safely() {
  local previous_line="$1"

  clear_defaults
  clear_gateway_routes
  if [[ -n "$previous_line" ]]; then
    restore_default_from_line "$previous_line" || true
  fi
}

ensure_runtime_dirs() {
  mkdir -p "$CONFIG_DIR" "$STATE_DIR"
}

selector_known() {
  local want="$1"
  local selector

  [[ "$want" == "native" ]] && return 0
  for selector in "${SELECTORS[@]}"; do
    [[ "$selector" == "$want" ]] && return 0
  done
  return 1
}

selector_to_resolved() {
  local selector="$1"
  local i

  if [[ "$selector" == "native" ]]; then
    echo "native"
    return 0
  fi

  for i in "${!SELECTORS[@]}"; do
    if [[ "${SELECTORS[$i]}" == "$selector" ]]; then
      echo "$i"
      return 0
    fi
  done

  return 1
}

load_auto_config() {
  ensure_runtime_dirs

  AUTO_SWITCH_ENABLED="0"
  AUTO_INTERVAL_MINUTES="$AUTO_INTERVAL_MINUTES_DEFAULT"

  if [[ -f "$AUTO_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$AUTO_CONFIG_FILE"
  fi

  [[ "$AUTO_SWITCH_ENABLED" == "1" ]] || AUTO_SWITCH_ENABLED="0"
  if ! [[ "$AUTO_INTERVAL_MINUTES" =~ ^[0-9]+$ ]] || (( AUTO_INTERVAL_MINUTES < 1 )); then
    AUTO_INTERVAL_MINUTES="$AUTO_INTERVAL_MINUTES_DEFAULT"
  fi
}

save_auto_config() {
  ensure_runtime_dirs
  cat > "$AUTO_CONFIG_FILE" <<EOF
AUTO_SWITCH_ENABLED=${AUTO_SWITCH_ENABLED}
AUTO_INTERVAL_MINUTES=${AUTO_INTERVAL_MINUTES}
EOF
  chmod 600 "$AUTO_CONFIG_FILE"
}

save_priority_order() {
  ensure_runtime_dirs
  printf '%s\n' "${PRIORITY_ORDER[@]}" > "$PRIORITY_FILE"
  chmod 600 "$PRIORITY_FILE"
}

load_priority_order() {
  local line selector
  local -a ordered
  local -A seen

  ensure_runtime_dirs

  if [[ -f "$PRIORITY_FILE" ]]; then
    while IFS= read -r line; do
      line="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$line")"
      [[ -n "$line" ]] || continue
      selector="${line,,}"
      [[ -z "${seen[$selector]:-}" ]] || continue
      if selector_known "$selector"; then
        ordered+=("$selector")
        seen["$selector"]=1
      fi
    done < "$PRIORITY_FILE"
  fi

  for selector in "${DEFAULT_PRIORITY_SELECTORS[@]}"; do
    [[ -z "${seen[$selector]:-}" ]] || continue
    ordered+=("$selector")
    seen["$selector"]=1
  done

  PRIORITY_ORDER=("${ordered[@]}")
  save_priority_order
}

valid_route_mtu() {
  local mtu="${1:-}"
  [[ "$mtu" =~ ^[0-9]+$ ]] || return 1
  (( mtu >= 1280 && mtu <= 1500 ))
}

route_mtu_for_selector() {
  local selector="$1"
  local mtu

  ensure_runtime_dirs
  [[ -f "$ROUTE_FIX_FILE" ]] || return 1
  mtu="$(awk -v selector="$selector" '$1 == selector && $2 ~ /^[0-9]+$/ { print $2; exit }' "$ROUTE_FIX_FILE")"
  valid_route_mtu "$mtu" || return 1
  echo "$mtu"
}

save_route_mtu_for_selector() {
  local selector="$1"
  local mtu="$2"
  local tmp

  selector="${selector,,}"
  selector_known "$selector" || { log error "未知线路: $selector"; return 1; }
  valid_route_mtu "$mtu" || { log error "MTU 应在 1280 到 1500 之间"; return 1; }

  ensure_runtime_dirs
  tmp="$(mktemp "${STATE_DIR}/route_fix.XXXXXX")"
  if [[ -f "$ROUTE_FIX_FILE" ]]; then
    awk -v selector="$selector" -v mtu="$mtu" '
      BEGIN { done = 0 }
      $1 == selector { print selector "	" mtu; done = 1; next }
      NF >= 2 { print $0 }
      END { if (!done) print selector "	" mtu }
    ' "$ROUTE_FIX_FILE" > "$tmp"
  else
    printf '%s\t%s\n' "$selector" "$mtu" > "$tmp"
  fi
  mv "$tmp" "$ROUTE_FIX_FILE"
  chmod 600 "$ROUTE_FIX_FILE"
}

priority_of_selector() {
  local selector="$1"
  local i

  for i in "${!PRIORITY_ORDER[@]}"; do
    if [[ "${PRIORITY_ORDER[$i]}" == "$selector" ]]; then
      echo "$((i + 1))"
      return 0
    fi
  done

  return 1
}

priority_of_resolved() {
  local resolved="$1"
  priority_of_selector "$(resolved_selector_name "$resolved")"
}

set_priority_order() {
  local token="$1"
  local priority="$2"
  local resolved selector current_index=-1 insert_index i rc
  local -a reordered

  [[ "$priority" =~ ^[0-9]+$ ]] || { log error "优先级必须是正整数"; return 1; }

  if resolved="$(resolve_target "$token")"; then
    :
  else
    rc=$?
    if (( rc == 2 )); then
      log warn "地区代号 ${token,,} 有多条线路，请直接使用线路代号，例如 jp-1"
    else
      log error "未找到线路: $token"
    fi
    return 1
  fi

  selector="$(resolved_selector_name "$resolved")"
  load_priority_order

  if (( priority < 1 || priority > ${#PRIORITY_ORDER[@]} )); then
    log error "优先级范围应在 1 到 ${#PRIORITY_ORDER[@]} 之间"
    return 1
  fi

  for i in "${!PRIORITY_ORDER[@]}"; do
    if [[ "${PRIORITY_ORDER[$i]}" == "$selector" ]]; then
      current_index="$i"
      break
    fi
  done

  [[ "$current_index" -ge 0 ]] || { log error "优先级列表中缺少线路: $selector"; return 1; }

  for i in "${!PRIORITY_ORDER[@]}"; do
    [[ "$i" -eq "$current_index" ]] && continue
    reordered+=("${PRIORITY_ORDER[$i]}")
  done

  insert_index=$((priority - 1))
  PRIORITY_ORDER=()
  for i in "${!reordered[@]}"; do
    if [[ "$i" -eq "$insert_index" ]]; then
      PRIORITY_ORDER+=("$selector")
    fi
    PRIORITY_ORDER+=("${reordered[$i]}")
  done
  if (( insert_index >= ${#reordered[@]} )); then
    PRIORITY_ORDER+=("$selector")
  fi

  save_priority_order
  log success "已将 $selector 调整到优先级 $priority"
  show_priority_list
}

letter_for_index() {
  local idx="$1"
  local letters="abcdefghijklmnopqrstuvwxyz"

  if (( idx >= 0 && idx < ${#letters} )); then
    echo "${letters:idx:1}"
  else
    echo "?"
  fi
}

priority_wizard_apply() {
  local raw="$1"
  local lowered="${raw,,}"
  local cleaned
  local -a dynamic_order chosen final_order
  local -A used by_letter
  local i letter selector

  cleaned="${lowered//[[:space:],>_-]/}"
  if [[ "$cleaned" =~ [^a-z] ]]; then
    log error "只支持输入字母顺序，例如: bc"
    return 1
  fi
  [[ -n "$cleaned" ]] || {
    log error "至少输入一个字母；如果想保持当前顺序，直接回车即可"
    return 1
  }

  for selector in "${PRIORITY_ORDER[@]}"; do
    [[ "$selector" == "native" ]] && continue
    dynamic_order+=("$selector")
  done

  for i in "${!dynamic_order[@]}"; do
    letter="$(letter_for_index "$i")"
    [[ "$letter" != "?" ]] || continue
    by_letter["$letter"]="${dynamic_order[$i]}"
  done

  for ((i = 0; i < ${#cleaned}; i++)); do
    letter="${cleaned:i:1}"
    selector="${by_letter[$letter]:-}"
    [[ -n "$selector" ]] || {
      log error "无效字母: $letter"
      return 1
    }
    [[ -z "${used[$selector]:-}" ]] || {
      log error "字母重复: $letter"
      return 1
    }
    chosen+=("$selector")
    used["$selector"]=1
  done

  final_order=("${chosen[@]}")
  for selector in "${dynamic_order[@]}"; do
    [[ -n "${used[$selector]:-}" ]] && continue
    final_order+=("$selector")
  done
  final_order+=("native")

  PRIORITY_ORDER=("${final_order[@]}")
  save_priority_order
  return 0
}

interactive_priority_wizard() {
  local answer
  local normalized

  ensure_runtime_dirs
  load_priority_order

  show_priority_wizard
  while true; do
    prompt_read answer "请输入优先字母顺序 [默认保持不变]: " || return 1
    normalized="${answer//[[:space:]]/}"
    if [[ -z "$normalized" ]]; then
      log info "已保留默认优先级顺序"
      show_priority_list
      return 0
    fi
    if priority_wizard_apply "$answer"; then
      log success "已更新优先级顺序"
      show_priority_list
      return 0
    fi
    log warn "请只输入有效且不重复的字母，例如: bc"
  done
}

mark_priority_guide_done() {
  ensure_runtime_dirs
  : > "$PRIORITY_GUIDE_FILE"
  chmod 600 "$PRIORITY_GUIDE_FILE"
}

maybe_prompt_priority_wizard() {
  local answer

  ensure_runtime_dirs
  [[ -f "$PRIORITY_GUIDE_FILE" ]] && return 0
  (( INTERACTIVE == 1 && QUIET == 0 && SCHEDULED == 0 )) || return 0

  section_title "首次自动切换前"
  section_note "在第一次自动切换前，你可以先手动调整一次优先级顺序。"
  section_note "如果现在跳过，后续仍可通过 qh priority list / set / wizard 继续调整。"

  prompt_read answer "是否现在手动调整自动切换优先级？ [y/N]: " || return 0
  echo
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    interactive_priority_wizard
  fi

  mark_priority_guide_done
}

set_auto_state() {
  local enabled="$1"

  load_auto_config
  AUTO_SWITCH_ENABLED="$enabled"
  save_auto_config

  if [[ "$enabled" == "1" ]]; then
    log success "已启用 IPv6 自动切换与定时巡检"
  else
    log success "已关闭 IPv6 自动切换与定时巡检"
  fi

  show_auto_status
}

resolved_selector_name() {
  local resolved="$1"

  if [[ "$resolved" == "native" ]]; then
    echo "native"
  else
    echo "${SELECTORS[$resolved]}"
  fi
}

resolved_target_name() {
  local resolved="$1"

  if [[ "$resolved" == "native" ]]; then
    echo "原生 IPv6"
  else
    echo "${REGIONS[$resolved]}"
  fi
}

resolved_display_source() {
  local resolved="$1"

  if [[ "$resolved" == "native" ]]; then
    echo "${NATIVE_SRC:-<auto>}"
  else
    echo "${IPS[$resolved]}"
  fi
}

resolved_gateway() {
  local resolved="$1"

  if [[ "$resolved" == "native" ]]; then
    echo "$NATIVE_VIA"
  else
    echo "${GWS[$resolved]}"
  fi
}

resolved_expected_src() {
  local resolved="$1"

  if [[ "$resolved" == "native" ]]; then
    echo "$NATIVE_SRC"
  else
    echo "${IPS[$resolved]}"
  fi
}

resolved_matches_native_route() {
  local resolved="$1"

  [[ "$resolved" == "native" ]] && return 1
  ipv6_equal "${GWS[$resolved]}" "$NATIVE_VIA" || return 1
  [[ -n "$NATIVE_SRC" ]] || return 1
  ipv6_equal "${IPS[$resolved]}" "$NATIVE_SRC"
}

route_line_matches_resolved() {
  local line="$1"
  local resolved="$2"
  local via src want_via want_src

  [[ -n "$line" ]] || return 1

  via="$(route_field "$line" "via")"
  src="$(route_field "$line" "src")"
  want_via="$(resolved_gateway "$resolved")"
  want_src="$(resolved_expected_src "$resolved")"

  ipv6_equal "$via" "$want_via" || return 1
  [[ -z "$want_src" ]] && return 0
  ipv6_equal "$src" "$want_src"
}

current_route_matches_resolved() {
  local resolved="$1"
  local line

  line="$(pick_best_default_route "$IFACE" || true)"
  route_line_matches_resolved "$line" "$resolved"
}

native_alias_selectors() {
  local i
  local aliases=()

  for i in "${!SELECTORS[@]}"; do
    if resolved_matches_native_route "$i"; then
      aliases+=("${SELECTORS[$i]}")
    fi
  done

  printf '%s' "${aliases[*]:-}"
}

resolved_probe_bind() {
  local resolved="$1"

  if [[ "$resolved" == "native" ]]; then
    if [[ -n "$NATIVE_SRC" ]]; then
      echo "$NATIVE_SRC"
    else
      echo "$IFACE"
    fi
  else
    echo "${IPS[$resolved]}"
  fi
}

apply_resolved_target() {
  local resolved="$1"

  if [[ "$resolved" == "native" ]]; then
    apply_native_impl
  else
    apply_dynamic_impl "$resolved"
  fi
}

probe_ipv6_only() {
  local bind="$1"

  if command -v ping >/dev/null 2>&1; then
    ping -6 -n -c "$PROBE_PING_COUNT" -W "$PROBE_PING_TIMEOUT" -I "$bind" "$PROBE_IPV6_TARGET" >/dev/null 2>&1
    return $?
  fi

  if command -v ping6 >/dev/null 2>&1; then
    ping6 -n -c "$PROBE_PING_COUNT" -W "$PROBE_PING_TIMEOUT" -I "$bind" "$PROBE_IPV6_TARGET" >/dev/null 2>&1
    return $?
  fi

  log error "缺少 ping 或 ping6，无法执行纯 IPv6 连通性检测"
  return 127
}

probe_ipv6_route_only() {
  if command -v ping >/dev/null 2>&1; then
    ping -6 -n -c "$PROBE_PING_COUNT" -W "$PROBE_PING_TIMEOUT" "$PROBE_IPV6_TARGET" >/dev/null 2>&1
    return $?
  fi

  if command -v ping6 >/dev/null 2>&1; then
    ping6 -n -c "$PROBE_PING_COUNT" -W "$PROBE_PING_TIMEOUT" "$PROBE_IPV6_TARGET" >/dev/null 2>&1
    return $?
  fi

  log error "缺少 ping 或 ping6，无法执行纯 IPv6 连通性检测"
  return 127
}

probe_mtu_payload() {
  local bind="$1"
  local payload="$2"
  if command -v ping >/dev/null 2>&1; then
    ping -6 -n -c 1 -W "$PROBE_PING_TIMEOUT" -M do -s "$payload" -I "$bind" "$PROBE_IPV6_TARGET" >/dev/null 2>&1
    return $?
  fi
  if command -v ping6 >/dev/null 2>&1; then
    ping6 -n -c 1 -W "$PROBE_PING_TIMEOUT" -M do -s "$payload" -I "$bind" "$PROBE_IPV6_TARGET" >/dev/null 2>&1
    return $?
  fi
  return 127
}

probe_http_only() {
  local bind="$1"
  command -v curl >/dev/null 2>&1 || { log error "缺少 curl，无法执行 HTTPS 出口检测"; return 127; }
  curl -6 --interface "$bind" --connect-timeout "$PROBE_HTTP_TIMEOUT" -m "$PROBE_HTTP_MAX_TIME" -fsS -o /dev/null "$PROBE_HTTP_URL" >/dev/null 2>&1
}

probe_http_public_ip() {
  local bind="$1"
  command -v curl >/dev/null 2>&1 || return 127
  curl -6 --interface "$bind" --connect-timeout "$PROBE_HTTP_TIMEOUT" -m "$PROBE_HTTP_MAX_TIME" -fsS "$PROBE_HTTP_URL" 2>/dev/null | head -n 1
}

print_route_diagnostics() {
  local bind="$1"
  local route_line neigh_via neigh_line
  if [[ "$bind" == *:* ]]; then
    route_line="$(ip -6 route get "$PROBE_IPV6_TARGET" from "$bind" oif "$IFACE" 2>/dev/null | awk 'NR == 1 { print; exit }' || true)"
  else
    route_line="$(ip -6 route get "$PROBE_IPV6_TARGET" oif "$IFACE" 2>/dev/null | awk 'NR == 1 { print; exit }' || true)"
  fi
  status_line "路由选择" "${route_line:-<无法获取>}"
  neigh_via="$(route_field "$route_line" "via")"
  if [[ -n "$neigh_via" ]]; then
    neigh_line="$(ip -6 neigh show dev "$IFACE" 2>/dev/null | awk -v via="$neigh_via" '$1 == via { print; exit }' || true)"
    status_line "网关邻居" "${neigh_line:-<未解析>}"
  fi
}

print_mtu_probe_summary() {
  local bind="$1"
  if probe_mtu_payload "$bind" "$PROBE_MTU_SAFE_PAYLOAD"; then
    status_line "MTU 安全包" "${PROBE_MTU_SAFE_PAYLOAD} payload 正常"
  else
    status_line "MTU 安全包" "${PROBE_MTU_SAFE_PAYLOAD} payload 异常"
  fi
  if probe_mtu_payload "$bind" "$PROBE_MTU_LARGE_PAYLOAD"; then
    status_line "MTU 大包" "${PROBE_MTU_LARGE_PAYLOAD} payload 正常"
  else
    status_line "MTU 大包" "${PROBE_MTU_LARGE_PAYLOAD} payload 异常或被本机 MTU 限制"
  fi
}

probe_native_ipv6_only() {
  local rc

  if [[ -n "$NATIVE_SRC" ]]; then
    if probe_ipv6_only "$NATIVE_SRC"; then
      return 0
    fi
    rc=$?
    log warn "原生地址直连检测失败，改用网卡 ${IFACE} 再试一次"
  fi

  if probe_ipv6_only "$IFACE"; then
    return 0
  fi

  rc=$?
  log warn "网卡绑定检测失败，改用当前原生默认路由再试一次"
  if probe_ipv6_route_only; then
    return 0
  fi

  return $?
}

probe_result_text() {
  local result="$1"

  if [[ "$result" == "OK" ]]; then
    echo "正常"
    return 0
  fi

  if [[ "$result" =~ ^FAIL\(([0-9]+)\)$ ]]; then
    echo "异常 (退出码 ${BASH_REMATCH[1]})"
    return 0
  fi

  echo "异常"
}

probe_resolved_target() {
  local resolved="$1"
  local previous_line selector target_name source_label bind result rc priority
  local icmp_ok=0 http_ok=0 public_ip=""

  previous_line="$(pick_best_default_route "$IFACE" || true)"
  selector="$(resolved_selector_name "$resolved")"
  target_name="$(resolved_target_name "$resolved")"
  source_label="$(resolved_display_source "$resolved")"
  bind="$(resolved_probe_bind "$resolved")"
  priority="$(priority_of_selector "$selector" 2>/dev/null || true)"
  result="FAIL"
  rc=0

  if apply_resolved_target "$resolved"; then
    if [[ "$resolved" == "native" ]]; then
      if probe_native_ipv6_only; then
        icmp_ok=1
      else
        rc=$?
      fi
    elif probe_ipv6_only "$bind"; then
      icmp_ok=1
    else
      rc=$?
    fi

    if (( icmp_ok == 1 )); then
      if probe_http_only "$bind"; then
        http_ok=1
        public_ip="$(probe_http_public_ip "$bind" || true)"
      else
        rc=$?
      fi
    fi

    if (( icmp_ok == 1 && http_ok == 1 )); then
      result="OK"
      rc=0
    else
      [[ "$rc" -eq 0 ]] && rc=1
      result="FAIL($rc)"
    fi
  else
    rc=$?
    result="FAIL($rc)"
  fi

  restore_previous_route_safely "$previous_line"
  LAST_SCAN_SELECTORS+=("$selector")
  LAST_SCAN_RESULTS+=("$result")
  if (( QUIET == 0 )); then
    printf -- '- %s | %s
' "$selector" "$target_name"
    printf '  优先级: %s
' "${priority:--}"
    printf '  源地址: %s
' "$source_label"
    printf '  ICMPv6 小包：%s
' "$([[ "$icmp_ok" == "1" ]] && echo 正常 || echo 异常)"
    print_mtu_probe_summary "$bind"
    printf '  HTTPS 出口：%s%s
' "$([[ "$http_ok" == "1" ]] && echo 正常 || echo 异常)" "${public_ip:+ ($public_ip)}"
    printf '  综合结果：%s
' "$(probe_result_text "$result")"
  fi
  return "$rc"
}

test_connectivity() {
  local line bind current quick_ok=0 http_ok=0 public_ip=""

  line="$(pick_best_default_route "$IFACE" || true)"
  current="$(current_selector)"
  bind="$(route_field "$line" "src")"
  [[ -n "$bind" ]] || bind="$IFACE"

  section_title "当前线路连通性测试"
  status_line "当前线路" "$(describe_selection "$current")"
  status_line "检测绑定" "$bind"
  status_line "ICMP 目标" "$PROBE_IPV6_TARGET"
  status_line "HTTPS 目标" "$PROBE_HTTP_URL"
  print_route_diagnostics "$bind"

  if [[ "$current" == "native" ]]; then
    if probe_native_ipv6_only; then quick_ok=1; fi
  elif probe_ipv6_only "$bind"; then
    quick_ok=1
  fi

  if (( quick_ok == 1 )); then log success "ICMPv6 小包连通：正常"; else log error "ICMPv6 小包连通：异常"; fi
  print_mtu_probe_summary "$bind"

  if probe_http_only "$bind"; then
    http_ok=1
    public_ip="$(probe_http_public_ip "$bind" || true)"
    log success "HTTPS 出口检测：正常${public_ip:+，出口 $public_ip}"
  else
    log error "HTTPS 出口检测：异常"
    if (( quick_ok == 1 )); then
      log warn "ICMPv6 小包正常但 HTTPS 异常，常见原因是 PMTU/MTU 黑洞；可执行 qh repair ${current} 尝试降 MTU 修复"
    fi
  fi
  (( quick_ok == 1 && http_ok == 1 ))
}

apply_native_impl() {
  local mtu=""
  mtu="$(route_mtu_for_selector native 2>/dev/null || true)"
  clear_defaults
  clear_gateway_routes
  ensure_gateway_route "$NATIVE_VIA"
  replace_default_route "$NATIVE_VIA" "$NATIVE_SRC" "$NATIVE_METRIC" "$NATIVE_ONLINK" "$mtu"
}

apply_dynamic_impl() {
  local idx="$1"
  local gw="${GWS[$idx]}"
  local selector mtu

  selector="${SELECTORS[$idx]}"
  mtu="$(route_mtu_for_selector "$selector" 2>/dev/null || true)"

  clear_defaults
  clear_gateway_routes
  ensure_gateway_route "$gw"
  replace_default_route "$gw" "${IPS[$idx]}" "100" "0" "$mtu"
}

switch_with_rollback() {
  local success_message="$1"
  shift

  local previous_line
  previous_line="$(pick_best_default_route "$IFACE" || true)"

  if "$@"; then
    log success "$success_message"
    show_status
    return 0
  fi

  local rc=$?
  log error "切换失败，正在回滚到上一个默认路由..."
  clear_defaults
  clear_gateway_routes
  if [[ -n "$previous_line" ]]; then
    restore_default_from_line "$previous_line" || true
  fi
  show_status
  return "$rc"
}

apply_route_mtu_fix() {
  local resolved="$1"
  local mtu="${2:-$DEFAULT_REPAIR_MTU}"
  local selector
  selector="$(resolved_selector_name "$resolved")"
  save_route_mtu_for_selector "$selector" "$mtu"
  apply_resolved_target "$resolved"
  log success "已为线路 $selector 写入并应用 MTU $mtu 修复"
}

repair_target() {
  local token="${1:-}"
  local mtu="${2:-$DEFAULT_REPAIR_MTU}"
  local current resolved selector bind public_ip
  valid_route_mtu "$mtu" || { log error "MTU 应在 1280 到 1500 之间"; return 1; }
  if [[ -z "$token" ]]; then
    current="$(current_selector)"
    [[ "$current" != "none" && "$current" != "unknown" ]] || { log error "当前线路无法识别，请指定要修复的线路，例如 qh repair jp-1"; return 1; }
    resolved="$(selector_to_resolved "$current")"
  else
    resolved="$(resolve_target "$token")" || { log error "未找到线路: $token"; return 1; }
  fi
  selector="$(resolved_selector_name "$resolved")"
  bind="$(resolved_probe_bind "$resolved")"
  section_title "线路检测与修复"
  status_line "目标线路" "$selector | $(resolved_target_name "$resolved")"
  status_line "源地址" "$bind"
  status_line "修复 MTU" "$mtu"
  apply_resolved_target "$resolved"
  print_route_diagnostics "$bind"
  if probe_ipv6_only "$bind"; then
    log success "ICMPv6 小包连通：正常"
  else
    log error "ICMPv6 小包连通：异常；这不像单纯 MTU 问题，请先检查网关/路由/NDP"
    print_mtu_probe_summary "$bind"
    return 1
  fi
  print_mtu_probe_summary "$bind"
  if probe_http_only "$bind"; then
    public_ip="$(probe_http_public_ip "$bind" || true)"
    log success "HTTPS 出口检测已正常${public_ip:+，出口 $public_ip}，无需修复"
    return 0
  fi
  log warn "HTTPS 出口检测异常，开始应用 MTU $mtu 修复"
  apply_route_mtu_fix "$resolved" "$mtu"
  if probe_http_only "$bind"; then
    public_ip="$(probe_http_public_ip "$bind" || true)"
    log success "修复后 HTTPS 出口检测正常${public_ip:+，出口 $public_ip}"
    print_route_diagnostics "$bind"
    return 0
  fi
  log error "已应用 MTU $mtu，但 HTTPS 仍异常；请检查上游 ACL、防火墙或回程路由"
  print_route_diagnostics "$bind"
  return 1
}

probe_target() {
  local token="${1:-}"
  local ordinal="${2:-}"
  local resolved rc

  if [[ -z "$token" ]]; then
    probe_all_targets
    return $?
  fi

  if resolved="$(resolve_target "$token" "$ordinal")"; then
    :
  else
    rc=$?
    if (( rc == 2 )); then
      log warn "地区代号 ${token,,} 匹配到多条线路，请使用 ${token,,}-1 / ${token,,}-2，或运行 qh 按序号选择"
    else
      log error "未找到线路: ${token}${ordinal:+ $ordinal}"
    fi
    return 1
  fi

  load_priority_order
  LAST_SCAN_SELECTORS=()
  LAST_SCAN_RESULTS=()
  section_title "单条线路连通性测试"
  status_line "检测目标" "$PROBE_IPV6_TARGET"
  probe_resolved_target "$resolved"
}

write_last_probe_file() {
  local i selector priority

  ensure_runtime_dirs
  {
    printf '# generated_at=%s\n' "$(date '+%F %T %z')"
    printf 'priority\tselector\tresult\n'
    for i in "${!LAST_SCAN_SELECTORS[@]}"; do
      selector="${LAST_SCAN_SELECTORS[$i]}"
      priority="$(priority_of_selector "$selector" 2>/dev/null || true)"
      printf '%s\t%s\t%s\n' "${priority:--}" "$selector" "${LAST_SCAN_RESULTS[$i]}"
    done
  } > "$LAST_PROBE_FILE"
}

best_healthy_selector() {
  local i

  for i in "${!LAST_SCAN_SELECTORS[@]}"; do
    if [[ "${LAST_SCAN_RESULTS[$i]}" == "OK" ]]; then
      echo "${LAST_SCAN_SELECTORS[$i]}"
      return 0
    fi
  done

  return 1
}

scan_all_targets() {
  local selector resolved rc=0

  load_priority_order
  LAST_SCAN_SELECTORS=()
  LAST_SCAN_RESULTS=()

  if (( QUIET == 0 )); then
    section_title "全部线路连通性测试"
    status_line "检测目标" "$PROBE_IPV6_TARGET"
  fi

  for selector in "${PRIORITY_ORDER[@]}"; do
    resolved="$(selector_to_resolved "$selector")"
    if ! probe_resolved_target "$resolved"; then
      rc=1
    fi
  done

  write_last_probe_file
  return "$rc"
}

probe_all_targets() {
  local ok_count=0
  local fail_count=0
  local rc=0
  local result

  log info "开始逐条检测全部线路的 IPv6/HTTPS/MTU 连通性（仅 IPv6，不触及 IPv4）"
  scan_all_targets || rc=1

  for result in "${LAST_SCAN_RESULTS[@]}"; do
    if [[ "$result" == "OK" ]]; then
      ok_count=$((ok_count + 1))
    else
      fail_count=$((fail_count + 1))
      rc=1
    fi
  done

  log info "检测完成：正常 $ok_count，异常 $fail_count"
  return "$rc"
}

auto_switch_best_target() {
  local current current_priority current_health best_selector best_priority i

  current="$(current_selector)"
  load_priority_order
  current_priority="$(priority_of_selector "$current" 2>/dev/null || true)"

  log info "开始执行自动优先级切换（先全量检测，再按优先级直接切换）"
  print_kv "当前线路" "$(describe_selection "$current")"
  print_kv "当前优先级" "${current_priority:-未设置}"

  scan_all_targets || true
  best_selector="$(best_healthy_selector || true)"

  if [[ -z "$best_selector" ]]; then
    log error "没有找到可用的 IPv6 线路，当前路由将保持不变"
    return 1
  fi

  best_priority="$(priority_of_selector "$best_selector" 2>/dev/null || true)"
  current_health="FAIL"
  for i in "${!LAST_SCAN_SELECTORS[@]}"; do
    if [[ "${LAST_SCAN_SELECTORS[$i]}" == "$current" ]]; then
      current_health="${LAST_SCAN_RESULTS[$i]}"
      break
    fi
  done

  print_kv "当前线路状态" "$(probe_result_text "$current_health")"
  print_kv "最佳可用线路" "$best_selector"
  print_kv "最佳优先级" "${best_priority:-未设置}"

  if [[ "$current" == "$best_selector" && "$current_health" == "OK" ]]; then
    log success "当前线路已经是最高优先级且可用的 IPv6 线路"
    return 0
  fi

  log warn "将直接切换到优先级最高的可用线路: $best_selector"
  switch_target "$best_selector"
}

handle_priority_command() {
  local subcmd="${1:-list}"

  case "${subcmd,,}" in
    list|"")
      show_priority_list
      ;;
    wizard)
      interactive_priority_wizard
      ;;
    set)
      [[ -n "${2:-}" && -n "${3:-}" ]] || {
        log error "用法: qh priority set <目标> <优先级>"
        return 1
      }
      set_priority_order "$2" "$3"
      ;;
    *)
      log error "未知 priority 子命令: $subcmd"
      return 1
      ;;
  esac
}

handle_auto_command() {
  local subcmd="${1:-run}"

  case "${subcmd,,}" in
    run|"")
      load_auto_config
      if (( SCHEDULED == 1 )) && [[ "$AUTO_SWITCH_ENABLED" != "1" ]]; then
        return 0
      fi
      maybe_prompt_priority_wizard
      auto_switch_best_target
      ;;
    on|enable)
      set_auto_state "1"
      ;;
    off|disable)
      set_auto_state "0"
      ;;
    status)
      show_auto_status
      ;;
    *)
      log error "未知 auto 子命令: $subcmd"
      return 1
      ;;
  esac
}

resolve_target() {
  local token="${1,,}"
  local ordinal="${2:-}"
  local i count=0 found=-1

  if [[ "$token" == "native" ]]; then
    echo "native"
    return 0
  fi

  if [[ "$token" =~ ^[0-9]+$ ]]; then
    if (( token == 0 )); then
      echo "native"
      return 0
    fi

    if (( token >= 1 && token <= ${#IPS[@]} )); then
      echo "$((token - 1))"
      return 0
    fi

    return 1
  fi

  for i in "${!SELECTORS[@]}"; do
    if [[ "${SELECTORS[$i],,}" == "$token" ]]; then
      echo "$i"
      return 0
    fi
  done

  if [[ -n "$ordinal" ]]; then
    [[ "$ordinal" =~ ^[0-9]+$ ]] || return 1
    for i in "${!CODES[@]}"; do
      if [[ "${CODES[$i],,}" == "$token" ]]; then
        count=$((count + 1))
        if (( count == ordinal )); then
          echo "$i"
          return 0
        fi
      fi
    done
    return 1
  fi

  for i in "${!CODES[@]}"; do
    if [[ "${CODES[$i],,}" == "$token" ]]; then
      count=$((count + 1))
      found="$i"
    fi
  done

  if (( count == 1 )); then
    echo "$found"
    return 0
  fi

  if (( count > 1 )); then
    return 2
  fi

  return 1
}

switch_target() {
  local token="$1"
  local ordinal="${2:-}"
  local resolved current rc note

  if resolved="$(resolve_target "$token" "$ordinal")"; then
    :
  else
    rc=$?
    if (( rc == 2 )); then
      log warn "地区代号 ${token,,} 匹配到多条线路，请使用 ${token,,}-1 / ${token,,}-2，或运行 qh 后按序号选择"
    else
      log error "未找到线路: ${token}${ordinal:+ $ordinal}"
    fi
    return 1
  fi

  if current_route_matches_resolved "$resolved"; then
    note="$(resolved_note "$resolved")"
    log info "当前路由已经匹配目标线路: $(resolved_selector_name "$resolved")"
    [[ -n "$note" ]] && log info "$note"
    show_status
    return 0
  fi

  current="$(current_selector)"
  if [[ "$resolved" == "native" && "$current" == "native" ]]; then
    log info "当前已经是原生 IPv6"
    show_status
    return 0
  fi

  if [[ "$resolved" != "native" && "$current" == "${SELECTORS[$resolved]}" ]]; then
    log info "当前已经在 [${REGIONS[$resolved]}] ${IPS[$resolved]}"
    show_status
    return 0
  fi

  if [[ "$resolved" == "native" ]]; then
    switch_with_rollback "已切换到: 原生 IPv6" apply_native_impl
  else
    switch_with_rollback "已切换到: [${REGIONS[$resolved]}] ${IPS[$resolved]} (${SELECTORS[$resolved]})" apply_dynamic_impl "$resolved"
  fi
}

show_cli_banner() {
  (( QUIET == 0 )) || return 0
  echo '=== QH DynamicV6 IPv6 切换工具 ==='
  echo '原生 IPv6 与 DynamicV6 多地区出口切换。'
  echo '支持手动切换、优先级自动切换、纯 IPv6 连通性检测与定时巡检。'
  echo '快捷命令: qh'
}

usage() {
  cat <<'EOF'
用法:
  qh                         进入交互菜单
  qh list                    查看全部线路
  qh status                  查看当前状态
  qh test                    检测当前线路 IPv6/HTTPS/MTU 连通性
  qh repair [目标] [MTU]      检测并尝试用 MTU 修复线路，默认 MTU 1280
  qh probe                   逐条检测全部线路 IPv6 连通性
  qh probe <目标>            检测指定线路 IPv6 连通性
  qh priority list           查看优先级顺序
  qh priority set <目标> <优先级>
  qh priority wizard         按字母向导调整优先级
  qh auto                    按优先级切到最佳可用线路
  qh auto on|off|status      开关或查看自动守护
  qh restore                 还原 DynamicV6 变更
  qh uninstall               还原变更并卸载 qh
  qh native                  切回原生 IPv6
  qh <序号>
  qh <线路代号>
  qh <地区代号> [序号]

示例:
  qh 2
  qh jp
  qh jp 2
  qh jp-2
  qh probe
  qh probe jp-2
  qh repair jp-2
  qh repair jp-2 1280
  qh priority list
  qh priority set jp-1 1
  qh priority wizard
  qh auto
  qh auto on
  qh restore
  qh uninstall
  qh --plain
EOF
}

resolved_note() {
  local resolved="$1"
  if resolved_matches_native_route "$resolved"; then
    echo "与原生线路相同"
  fi
}

describe_selection() {
  local selection="$1"
  local i

  case "$selection" in
    native)
      echo "原生 IPv6"
      ;;
    none)
      echo "未检测到默认 IPv6 路由"
      ;;
    unknown)
      echo "未识别线路（可能被手动修改过）"
      ;;
    *)
      for i in "${!SELECTORS[@]}"; do
        if [[ "${SELECTORS[$i]}" == "$selection" ]]; then
          echo "[${REGIONS[$i]}] ${IPS[$i]} via ${GWS[$i]} (${SELECTORS[$i]})"
          return 0
        fi
      done
      echo "$selection"
      ;;
  esac
}

current_selector() {
  local line via src i

  line="$(pick_best_default_route "$IFACE" || true)"
  [[ -n "$line" ]] || { echo "none"; return 0; }

  via="$(route_field "$line" "via")"
  src="$(route_field "$line" "src")"

  for i in "${!SELECTORS[@]}"; do
    if ipv6_equal "$src" "${IPS[$i]}" && ipv6_equal "$via" "${GWS[$i]}"; then
      echo "${SELECTORS[$i]}"
      return 0
    fi
  done

  if ipv6_equal "$via" "$NATIVE_VIA"; then
    if [[ -z "$NATIVE_SRC" ]] || ipv6_equal "$src" "$NATIVE_SRC"; then
      echo "native"
      return 0
    fi
  fi

  echo "unknown"
}

show_status() {
  local line current priority aliases current_note resolved

  load_priority_order
  line="$(pick_best_default_route "$IFACE" || true)"
  current="$(current_selector)"
  priority="$(priority_of_selector "$current" 2>/dev/null || true)"
  aliases="$(native_alias_selectors)"
  current_note=""

  if [[ "$current" == "native" && -n "$aliases" ]]; then
    current_note="同路由别名: ${aliases// /, }"
  elif [[ "$current" != "native" ]]; then
    if resolved="$(selector_to_resolved "$current" 2>/dev/null)"; then
      current_note="$(resolved_note "$resolved" || true)"
    fi
  fi

  section_title "当前状态"
  status_line "网卡" "$IFACE"
  status_line "当前线路" "$(describe_selection "$current")"
  status_line "优先级" "${priority:-未设置}"
  status_line "默认路由" "${line:-<none>}"
  [[ -n "$current_note" ]] && status_line "备注" "$current_note"
  return 0
}

list_all() {
  local current i state priority note

  load_priority_order
  current="$(current_selector)"
  section_title "可用线路"
  section_note "优先级数字越小越靠前，状态为“当前使用”表示该线路正在生效。"
  state=""
  [[ "$current" == "native" ]] && state="当前使用"
  priority="$(priority_of_selector "native" 2>/dev/null || true)"
  printf '0. native | 原生 IPv6\n'
  printf '   优先级: %s\n' "${priority:--}"
  printf '   源地址: %s\n' "${NATIVE_SRC:-<auto>}"
  printf '   网关: %s\n' "$NATIVE_VIA"
  [[ -n "$state" ]] && printf '   状态: %s\n' "$state"

  for i in "${!IPS[@]}"; do
    state=""
    [[ "$current" == "${SELECTORS[$i]}" ]] && state="当前使用"
    priority="$(priority_of_selector "${SELECTORS[$i]}" 2>/dev/null || true)"
    note="$(resolved_note "$i" || true)"
    printf '%s. %s | %s\n' "$((i + 1))" "${SELECTORS[$i]}" "${REGIONS[$i]}"
    printf '   优先级: %s\n' "${priority:--}"
    printf '   源地址: %s\n' "${IPS[$i]}"
    printf '   网关: %s\n' "${GWS[$i]}"
    [[ -n "$state" ]] && printf '   状态: %s\n' "$state"
    [[ -n "$note" ]] && printf '   备注: %s\n' "$note"
  done
  return 0
}

show_priority_list() {
  local current selector resolved state priority note

  load_priority_order
  current="$(current_selector)"
  section_title "优先级顺序"
  section_note "数字越小优先级越高，状态为“当前使用”表示该线路正在生效。"
  for selector in "${PRIORITY_ORDER[@]}"; do
    resolved="$(selector_to_resolved "$selector")"
    priority="$(priority_of_selector "$selector")"
    state=""
    [[ "$current" == "$selector" ]] && state="当前使用"
    note="$(resolved_note "$resolved" || true)"
    printf '%s. %s | %s\n' "$priority" "$selector" "$(resolved_target_name "$resolved")"
    printf '   源地址: %s\n' "$(resolved_display_source "$resolved")"
    [[ -n "$state" ]] && printf '   状态: %s\n' "$state"
    [[ -n "$note" ]] && printf '   备注: %s\n' "$note"
  done
  return 0
}

show_priority_wizard() {
  local -a dynamic_order
  local i selector resolved priority letter note

  load_priority_order
  for selector in "${PRIORITY_ORDER[@]}"; do
    [[ "$selector" == "native" ]] && continue
    dynamic_order+=("$selector")
  done

  section_title "优先级向导"
  section_note "请输入字母顺序，决定自动切换时哪些线路优先。"
  section_note "未写出的线路会按当前默认顺序自动顺延。"
  section_note "例如输入 bc，表示 b 第一、c 第二，其余自动接在后面。"
  for i in "${!dynamic_order[@]}"; do
    selector="${dynamic_order[$i]}"
    resolved="$(selector_to_resolved "$selector")"
    priority="$(priority_of_selector "$selector" 2>/dev/null || true)"
    letter="$(letter_for_index "$i")"
    note="$(resolved_note "$resolved" || true)"
    printf '%s. %s | %s | 当前优先级 %s\n' \
      "$letter" \
      "$selector" \
      "$(resolved_target_name "$resolved")" \
      "${priority:--}"
    printf '   源地址: %s\n' "$(resolved_display_source "$resolved")"
    [[ -n "$note" ]] && printf '   备注: %s\n' "$note"
  done
  section_note "直接回车表示保持当前顺序不变。"
}

show_auto_status() {
  local scheduler="未安装"
  local enabled_label="关闭"

  load_auto_config
  if command -v systemctl >/dev/null 2>&1 && [[ -f /etc/systemd/system/qh-autoheal.timer ]]; then
    scheduler="systemd 定时器"
  elif [[ -f /etc/cron.d/qh-autoheal ]]; then
    scheduler="cron 任务"
  fi
  [[ "$AUTO_SWITCH_ENABLED" == "1" ]] && enabled_label="开启"

  section_title "自动守护状态"
  status_line "启用状态" "$enabled_label"
  status_line "巡检间隔" "${AUTO_INTERVAL_MINUTES} 分钟"
  status_line "定时方式" "$scheduler"
}

pause_menu_return() {
  local answer=""

  (( INTERACTIVE == 1 && QUIET == 0 )) || return 0
  echo
  prompt_read answer "按回车返回主菜单..." || true
  echo
  return 0
}

confirm_menu_action() {
  local prompt="$1"
  local answer=""

  (( INTERACTIVE == 1 && QUIET == 0 )) || return 0
  prompt_read answer "$prompt [y/N]: " || return 1
  echo
  [[ "$answer" =~ ^[Yy]$ ]]
}

run_restore_script() {
  need_cmd curl
  need_cmd bash

  log info "正在执行 DynamicV6 还原脚本..."
  if curl -fsSL "$RESTORE_URL" | bash -s; then
    log success "已完成 DynamicV6 变更还原"
    return 0
  fi

  local rc=$?
  log error "执行 DynamicV6 还原脚本失败"
  return "$rc"
}

remove_auto_scheduler_artifacts() {
  rm -f "$AUTO_CRON"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now qh-autoheal.timer >/dev/null 2>&1 || true
  fi

  rm -f "$AUTO_SERVICE" "$AUTO_TIMER"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

cleanup_qh_runtime_files() {
  remove_auto_scheduler_artifacts
  rm -f "$PRIORITY_FILE" "$PRIORITY_GUIDE_FILE" "$AUTO_CONFIG_FILE" "$LAST_PROBE_FILE" "$ROUTE_FIX_FILE"
  rm -rf "$CONFIG_DIR" "$STATE_DIR"
}

restore_changes() {
  run_restore_script
}

uninstall_qh() {
  run_restore_script || return $?
  cleanup_qh_runtime_files
  rm -f "$CMD_PATH"
  log success "已还原 DynamicV6 变更并卸载 qh"
  return 0
}

menu_loop() {
  local choice target_input subcmd

  while true; do
    if command -v clear >/dev/null 2>&1 && [[ -t 1 ]]; then
      clear
    fi
    show_cli_banner
    show_status
    list_all
    echo
    section_title "请选择操作"
    menu_line 1 "切换线路"
    menu_line 2 "自动切到最佳可用线路"
    menu_line 3 "检测当前线路 IPv6 连通性"
    menu_line 4 "检测全部线路 IPv6 连通性"
    menu_line 5 "查看优先级顺序"
    menu_line 6 "优先级字母向导"
    menu_line 7 "自动守护 开启/关闭/状态"
    menu_line 8 "查看帮助"
    menu_line 9 "还原 DynamicV6 变更"
    menu_line 10 "卸载并删除 qh"
    menu_line 0 "退出"
    if ! prompt_read choice "请输入选择 [0-10]: "; then
      log error "无法读取菜单输入，请确认当前是在交互终端中运行 qh"
      return 1
    fi
    echo

    case "${choice,,}" in
      0|q|quit|exit)
        exit 0
        ;;
      1)
        prompt_read target_input "请输入线路序号或线路代号 [回车取消]: " || target_input=""
        echo
        if [[ -n "$target_input" ]]; then
          switch_target "$target_input" || true
          pause_menu_return
        fi
        ;;
      2)
        handle_auto_command run || true
        pause_menu_return
        ;;
      3)
        test_connectivity || true
        pause_menu_return
        ;;
      4)
        probe_all_targets || true
        pause_menu_return
        ;;
      5)
        show_priority_list
        pause_menu_return
        ;;
      6)
        interactive_priority_wizard || true
        pause_menu_return
        ;;
      7)
        prompt_read subcmd "请输入 on / off / status [status]: " || subcmd=""
        echo
        handle_auto_command "${subcmd:-status}" || true
        pause_menu_return
        ;;
      8|-h|--help|help)
        usage
        pause_menu_return
        ;;
      9)
        if confirm_menu_action "确认还原当前 DynamicV6 变更？"; then
          restore_changes || true
          pause_menu_return
        fi
        ;;
      10)
        if confirm_menu_action "确认还原变更并卸载 qh？"; then
          if uninstall_qh; then
            exit 0
          fi
          pause_menu_return
        fi
        ;;
      *)
        log warn "输入无效，请输入 0-10"
        ;;
    esac

    echo
  done
}

ARGS=()

parse_cli() {
  while (($#)); do
    case "$1" in
      --plain)
        PLAIN=1
        shift
        ;;
      --quiet)
        QUIET=1
        shift
        ;;
      --scheduled)
        SCHEDULED=1
        QUIET=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        while (($#)); do
          ARGS+=("$1")
          shift
        done
        ;;
      *)
        ARGS+=("$1")
        shift
        ;;
    esac
  done
}

main() {
  parse_cli "$@"
  init_styles
  need_cmd ip

  if (( ${#ARGS[@]} == 0 )); then
    if (( INTERACTIVE == 1 )); then
      menu_loop
    else
      list_all
    fi
    return 0
  fi

  case "${ARGS[0],,}" in
    list)
      list_all
      ;;
    priority)
      handle_priority_command "${ARGS[1]:-}" "${ARGS[2]:-}" "${ARGS[3]:-}"
      ;;
    status)
      show_status
      ;;
    test)
      test_connectivity
      ;;
    probe)
      probe_target "${ARGS[1]:-}" "${ARGS[2]:-}"
      ;;
    repair)
      repair_target "${ARGS[1]:-}" "${ARGS[2]:-}"
      ;;
    auto)
      handle_auto_command "${ARGS[1]:-run}"
      ;;
    restore)
      restore_changes
      ;;
    uninstall)
      uninstall_qh
      ;;
    native)
      switch_target "native"
      ;;
    *)
      switch_target "${ARGS[0]}" "${ARGS[1]:-}"
      ;;
  esac
}

main "$@"
SWITCHV6EOF
  } > "$GENERATED_CMD_PATH"

  chmod +x "$GENERATED_CMD_PATH"
}

run_generated_cmd() {
  local cmd=("$GENERATED_CMD_PATH")
  (( PLAIN == 1 )) && cmd+=(--plain)
  cmd+=("$@")
  "${cmd[@]}"
}

target_note() {
  local idx="$1"

  if ipv6_equal "${IPS[$idx]}" "${native_src:-}" && ipv6_equal "${GWS[$idx]}" "$native_via"; then
    echo "与原生线路相同"
  fi
}

print_initial_targets() {
  local i note

  section_title "可用线路"
  printf '0. native | 原生 IPv6\n'
  printf '   源地址: %s\n' "${native_src:-自动选择}"
  printf '   网关: %s\n' "$native_via"
  for i in "${!IPS[@]}"; do
    note="$(target_note "$i" || true)"
    printf '%s. %s | %s\n' "$((i + 1))" "${SELECTORS[$i]}" "${REGIONS[$i]}"
    printf '   源地址: %s\n' "${IPS[$i]}"
    printf '   网关: %s\n' "${GWS[$i]}"
    [[ -n "$note" ]] && printf '   备注: %s\n' "$note"
  done
  return 0
}

prompt_initial_target() {
  local choice target lowered selector

  if (( INTERACTIVE == 0 )); then
    log info "非交互模式，跳过首次线路选择"
    return 0
  fi

  echo
  section_title "首次启用线路"
  section_note "安装已完成，请先选择当前要启用的一条 IPv6 线路。"
  section_note "这里只决定当前生效线路，后续仍可通过 qh 随时切换。"
  print_initial_targets

  while true; do
    prompt_read choice "请选择线路 [0]: " || { log error "无法读取首次线路选择，请确认当前终端可交互"; return 1; }
    echo
    choice="${choice:-0}"
    target=""
    lowered="${choice,,}"

    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      if (( choice == 0 )); then
        target="native"
      elif (( choice >= 1 && choice <= ${#SELECTORS[@]} )); then
        target="${SELECTORS[$((choice - 1))]}"
      fi
    else
      if [[ "$lowered" == "native" ]]; then
        target="native"
      else
        for selector in "${SELECTORS[@]}"; do
          if [[ "${selector,,}" == "$lowered" ]]; then
            target="$selector"
            break
          fi
        done
      fi
    fi

    if [[ -z "$target" ]]; then
      log warn "输入无效，请输入序号、native 或线路代号"
      continue
    fi

    if run_generated_cmd "$target"; then
      return 0
    fi

    log warn "首次切换失败，请重新选择"
  done
}

prompt_auto_switch_toggle() {
  local answer prompt_suffix saved_interval

  AUTO_SWITCH_ENABLED="$QH_AUTO_ENABLE_DEFAULT"
  saved_interval="$QH_AUTO_INTERVAL_MINUTES"
  if [[ -f "$QH_AUTO_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$QH_AUTO_CONFIG_FILE"
    [[ "$AUTO_SWITCH_ENABLED" == "1" ]] || AUTO_SWITCH_ENABLED="0"
    if normalize_auto_interval "${AUTO_INTERVAL_MINUTES:-}" >/dev/null 2>&1; then
      QH_AUTO_INTERVAL_MINUTES="$(normalize_auto_interval "$AUTO_INTERVAL_MINUTES")"
    else
      QH_AUTO_INTERVAL_MINUTES="$saved_interval"
    fi
  fi

  if (( INTERACTIVE == 0 || ASSUME_YES == 1 )); then
    return 0
  fi

  prompt_suffix="y/N"
  [[ "$AUTO_SWITCH_ENABLED" == "1" ]] && prompt_suffix="Y/n"

  section_title "自动守护"
  section_note "自动守护会定时检查 IPv6 连通性，并按优先级切换到最佳可用线路。"
  section_note "首次真正执行 qh auto 时，仍会再询问一次是否手动调整优先级。"
  section_note "如果这里启用，下一步会继续询问巡检间隔，默认 2 分钟。"

  prompt_read answer "是否启用 IPv6 自动切换与定时巡检？ [${prompt_suffix}]: " || { log error "无法读取自动守护选项"; exit 1; }
  if [[ "$prompt_suffix" == "Y/n" ]]; then
    [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]] && AUTO_SWITCH_ENABLED="1" || AUTO_SWITCH_ENABLED="0"
  else
    [[ "$answer" =~ ^[Yy]$ ]] && AUTO_SWITCH_ENABLED="1" || AUTO_SWITCH_ENABLED="0"
  fi
}

prompt_auto_interval() {
  local answer interval

  if [[ "$AUTO_SWITCH_ENABLED" != "1" ]]; then
    return 0
  fi

  if ! interval="$(normalize_auto_interval "$QH_AUTO_INTERVAL_MINUTES" 2>/dev/null)"; then
    interval="2"
  fi
  QH_AUTO_INTERVAL_MINUTES="$interval"

  if (( INTERACTIVE == 0 || ASSUME_YES == 1 )); then
    return 0
  fi

  section_title "巡检间隔"
  section_note "请输入自动巡检间隔，单位为分钟。"
  section_note "直接回车使用默认值 2；如果宿主机回退到 cron，建议填写 1-59。"

  while true; do
    prompt_read answer "巡检间隔 [${QH_AUTO_INTERVAL_MINUTES}]: " || { log error "无法读取巡检间隔"; exit 1; }
    answer="${answer:-$QH_AUTO_INTERVAL_MINUTES}"
    if interval="$(normalize_auto_interval "$answer" 2>/dev/null)"; then
      QH_AUTO_INTERVAL_MINUTES="$interval"
      return 0
    fi
    log warn "请输入大于等于 1 的整数分钟值"
  done
}

parse_args "$@"
init_styles
show_installer_banner

if ! [[ "$QH_AUTO_INTERVAL_MINUTES" =~ ^[0-9]+$ ]] || (( QH_AUTO_INTERVAL_MINUTES < 1 )); then
  QH_AUTO_INTERVAL_MINUTES=2
fi

need_cmd curl
need_cmd jq
need_cmd ip

if ! is_utf8_locale; then
  log warn "当前 locale 不是 UTF-8，中文可能显示异常；可追加 --plain 关闭彩色输出"
fi

select_iface
log info "将使用网卡: $IFACE"

step 1 "记录当前原生 IPv6 默认路由"
if ! detect_native_profile "$IFACE"; then
  exit 1
fi

print_kv "IFACE" "$IFACE"
print_kv "Native via" "$native_via"
print_kv "Native src" "${native_src:-<none>}"
print_kv "Metric" "$native_metric"
print_kv "Onlink" "$native_onlink"

step 2 "下载 DynamicV6 分发脚本"
download_client_script
print_kv "Client URL" "$CLIENT_URL"
print_kv "Temp file" "$CLIENT_SCRIPT"

if ! confirm "即将执行下载到本机的 DynamicV6 分发脚本，并在 $IFACE 上注入 DynamicV6 地址，是否继续？"; then
  log warn "已取消，本次没有做任何改动。"
  exit 1
fi

step 3 "执行 DynamicV6 分发脚本"
DYNAMICV6_SELECT_MODE=all \
DYNAMICV6_AUTO_TIMER=0 \
DYNAMICV6_ROUTE_POLICY=add \
bash "$CLIENT_SCRIPT" --run "$IFACE" </dev/null

step 4 "从网卡读取 DynamicV6 /128 地址"
mapfile -t CIDRS < <(ip -6 -o addr show dev "$IFACE" scope global | awk '{print $4}' | grep '/128$' | awk '!seen[$0]++' || true)
(( ${#CIDRS[@]} > 0 )) || { log error "没有在 $IFACE 上发现 /128 DynamicV6 地址"; exit 1; }
printf '  - %s\n' "${CIDRS[@]}"

step 5 "调用 DynamicV6 API 获取地区与网关映射"
VM_UUID="$(detect_vm_uuid || true)"
[[ -n "$VM_UUID" ]] || { log error "无法检测 vm_uuid"; exit 1; }

status_json="$(
  curl "${CURL_BASE_ARGS[@]}" \
    --max-time 15 \
    -X POST "$API_BASE/status" \
    -H 'Content-Type: application/json' \
    -d "{\"vm_uuid\":\"$VM_UUID\"}"
)"

echo "$status_json" | jq -e . >/dev/null 2>&1 || { log error "API 返回了非 JSON 内容"; exit 1; }

leases_json="$(echo "$status_json" | jq -c '
  def to_arr:
    if . == null then []
    elif (type == "array") then .
    elif (type == "object") then [.]
    else []
    end;
  def lease_sources:
    [
      .,
      .data?,
      .result?,
      .payload?
    ];
  [
    lease_sources[]?
    | ((. | to_arr) + (.leases | to_arr) + (.lease | to_arr))[]
  ]
  | map(select(type == "object"))
  | unique_by(.ipv6_cidr // "")
')"

declare -A GW_BY_CIDR=()
declare -A CODE_BY_CIDR=()
declare -A PREFIX_BY_CIDR=()
declare -A GW_BY_CIDR_KEY=()
declare -A CODE_BY_CIDR_KEY=()
declare -A PREFIX_BY_CIDR_KEY=()

while IFS='|' read -r cidr gw code prefix; do
  cidr_key=""
  [[ -n "$cidr" ]] || continue
  [[ -n "$code" ]] || code="unknown"
  [[ -n "$prefix" && "$prefix" != "null" ]] || prefix=""
  [[ -n "$gw" && "$gw" != "null" ]] || gw=""

  CODE_BY_CIDR["$cidr"]="$code"
  PREFIX_BY_CIDR["$cidr"]="$prefix"
  if [[ -n "$gw" ]]; then
    GW_BY_CIDR["$cidr"]="$gw"
  fi

  cidr_key="$(normalize_cidr_key "$cidr" 2>/dev/null || true)"
  if [[ -n "$cidr_key" ]]; then
    CODE_BY_CIDR_KEY["$cidr_key"]="$code"
    PREFIX_BY_CIDR_KEY["$cidr_key"]="$prefix"
    if [[ -n "$gw" ]]; then
      GW_BY_CIDR_KEY["$cidr_key"]="$gw"
    fi
  fi
done < <(
  echo "$leases_json" | jq -r '
    .[]
    | select((.ipv6_cidr? | type) == "string" and (.ipv6_cidr | length > 0))
    | "\(.ipv6_cidr)|\(if (.gateway? | type) == "string" then .gateway else "" end)|\(.wg_interface? // .region? // .location? // "unknown")|\(if (.prefix? | type) == "string" then .prefix else "" end)"
  '
)

IPS=()
GWS=()
CODES=()
REGIONS=()
SELECTORS=()

declare -A CODE_ORDERS=()

for cidr in "${CIDRS[@]}"; do
  ip_only="${cidr%/*}"
  cidr_key="$(normalize_cidr_key "$cidr" 2>/dev/null || true)"
  gw="${GW_BY_CIDR[$cidr]:-}"
  prefix="${PREFIX_BY_CIDR[$cidr]:-}"
  raw_code="${CODE_BY_CIDR[$cidr]:-unknown}"

  if [[ -n "$cidr_key" ]]; then
    [[ -n "$gw" ]] || gw="${GW_BY_CIDR_KEY[$cidr_key]:-}"
    [[ -n "$prefix" ]] || prefix="${PREFIX_BY_CIDR_KEY[$cidr_key]:-}"
    if [[ "$raw_code" == "unknown" ]]; then
      raw_code="${CODE_BY_CIDR_KEY[$cidr_key]:-unknown}"
    fi
  fi

  code="$(normalize_region_code "$raw_code")"

  if [[ -z "$gw" ]]; then
    gw="$(route_gateway_for_dynamic_cidr "$cidr" "$prefix" "$IFACE" 2>/dev/null || true)"
    if [[ -n "$gw" ]]; then
      log warn "API 未返回 $cidr 的 gateway，已从当前路由表推导为 $gw"
    fi
  fi

  if [[ -z "$gw" ]]; then
    if [[ -n "$prefix" ]]; then
      gw="$(dynamic_gateway_guess_from_prefix "$prefix" 2>/dev/null || true)"
      if [[ -n "$gw" ]]; then
        log warn "API 未返回 $cidr 的 gateway，已根据前缀 $prefix 推导为 $gw"
      fi
    fi
  fi

  if [[ -z "$gw" ]]; then
    log warn "跳过: $cidr，API 未返回 gateway，且无法从 prefix/路由表推导"
    continue
  fi

  label="$(region_label "$code")"
  order=$(( ${CODE_ORDERS[$code]:-0} + 1 ))
  CODE_ORDERS["$code"]="$order"
  selector="${code}-${order}"

  IPS+=("$ip_only")
  GWS+=("$gw")
  CODES+=("$code")
  REGIONS+=("$label")
  SELECTORS+=("$selector")

  print_kv "$selector" "[$label] $ip_only -> $gw"
done

(( ${#IPS[@]} > 0 )) || { log error "API 返回中没有解析到可用的 IPv6 与网关映射"; exit 1; }

step 6 "生成 ${GENERATED_CMD_PATH}"
write_switch_script
sync_priority_file

echo
prompt_initial_target
echo

prompt_auto_switch_toggle
prompt_auto_interval
write_auto_config

step 7 "安装自动巡检定时任务"
if ! install_auto_scheduler; then
  log warn "自动巡检定时任务安装失败，可稍后手动检查 systemd/cron 环境"
fi
write_auto_config

auto_guard_label="关闭"
[[ "$AUTO_SWITCH_ENABLED" == "1" ]] && auto_guard_label="开启"

log success "安装完成。"
section_title "安装结果"
status_line "网卡" "$IFACE"
status_line "线路数量" "${#IPS[@]}"
status_line "自动守护" "$auto_guard_label"
status_line "巡检间隔" "${QH_AUTO_INTERVAL_MINUTES} 分钟"
section_title "常用命令"
menu_line 1 "qh                    进入交互菜单"
menu_line 2 "qh list               查看全部线路"
menu_line 3 "qh priority list      查看优先级顺序"
menu_line 4 "qh priority set jp-1 1"
menu_line 5 "qh priority wizard    按字母向导调整优先级"
menu_line 6 "qh status             查看当前状态"
menu_line 7 "qh test               检测当前线路"
menu_line 8 "qh probe              检测全部线路"
menu_line 9 "qh auto               切换到最佳可用线路"
menu_line 10 "qh auto on|off|status 管理自动守护"
menu_line 11 "qh restore            还原 DynamicV6 变更"
menu_line 12 "qh uninstall          还原变更并卸载 qh"
menu_line 13 "qh native             切回原生 IPv6"
for selector in "${SELECTORS[@]}"; do
  echo "  qh $selector"
done
