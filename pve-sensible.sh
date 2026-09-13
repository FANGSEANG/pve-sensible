#!/usr/bin/env bash
# pve-sensible - a small, reversible helper for Proxmox VE 9
# License: MIT
set -Eeuo pipefail

readonly APP="pve-sensible"
readonly STATE_DIR="/var/lib/${APP}"
readonly LIB_DIR="/usr/local/lib/${APP}"
readonly SUMMARY_HELPER="${LIB_DIR}/summary.sh"
readonly OVERVIEW_CONF="/etc/pve-sensible/overview.conf"
readonly NODES_PM="/usr/share/perl5/PVE/API2/Nodes.pm"
readonly MANAGER_JS="/usr/share/pve-manager/js/pvemanagerlib.js"
readonly TOOLKIT_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
readonly ROLLBACK_HELPER="${LIB_DIR}/rollback-ui.sh"
readonly ROLLBACK_UNIT="pve-sensible-ui-rollback"
CURRENT_BACKUP_DIR=''
CURRENT_ROLLBACK_UNIT=''

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
info() { printf '[%s] %s\n' "$APP" "$*"; }
need_root() { [[ $EUID -eq 0 ]] || die '请使用 root 用户运行此脚本。'; }
need_pve9() {
  command -v pveversion >/dev/null || die '当前主机不是 Proxmox VE。'
  pveversion | grep -q 'pve-manager/9\.' || die '本脚本目前仅支持 Proxmox VE 9。'
}
backup() {
  local path="$1" manifest="$CURRENT_BACKUP_DIR/manifest.tsv"
  [[ -n "$CURRENT_BACKUP_DIR" ]] || die '内部错误：未创建本次操作的备份目录。'
  if [[ -e "$path" ]]; then
    cp -a -- "$path" "$CURRENT_BACKUP_DIR/$(basename "$path")"
    printf 'present\t%s\n' "$path" >>"$manifest"
    info "已备份：$CURRENT_BACKUP_DIR/$(basename "$path")"
  else
    printf 'absent\t%s\n' "$path" >>"$manifest"
    info "已记录原文件不存在：$path"
  fi
  chmod 0600 "$manifest"
}
begin_transaction() {
  local label="$1"
  CURRENT_BACKUP_DIR="$STATE_DIR/backups/$(date +%Y%m%d-%H%M%S-%N)-$label"
  install -d -m 0700 "$CURRENT_BACKUP_DIR"
}
confirm() {
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

write_summary_helper() {
  local target="${1:-$SUMMARY_HELPER}"
  [[ "$target" == "$SUMMARY_HELPER" ]] && install -d -m 0755 "$LIB_DIR"
  cat >"$target" <<'EOF'
#!/usr/bin/env bash
set -u
CPU_FREQ=1; CPU_LIMITS=1; CPU_THREAD=0; CPU_GOVERNOR=1; CPU_POWER=0; CPU_TEMP=1; CPU_CORE_TEMP=0; IGPU_TEMP=0; FAN_SPEED=0
UPS_INFO=1; DISK_BASE=1; DISK_POWER=0; DISK_IO=0; OVERVIEW_ALIGN=l
[[ -r /etc/pve-sensible/overview.conf ]] && . /etc/pve-sensible/overview.conf
one_line() { tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'; }

model=$(lscpu | awk -F: '/Model name:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
threads=$(nproc 2>/dev/null || echo '?')
freq=$(lscpu | awk -F: '/CPU MHz:/ {gsub(/^[[:space:]]+/, "", $2); printf "%.0f MHz", $2; exit}')
minmax=$(lscpu | awk -F: '/CPU min MHz:|CPU max MHz:/ {gsub(/^[[:space:]]+/, "", $2); printf "%s ", $2}' | xargs)
gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)
power=$(command -v turbostat >/dev/null 2>&1 && timeout 3s turbostat --quiet --show PkgWatt --interval 0.1 --num_iterations 1 2>/dev/null | tail -n1 | awk '{print $1 " W"}' || true)
cpu_line="CPU：${model:-未知型号} · ${threads} 线程"
[[ "$CPU_FREQ" == 1 && -n "$freq" ]] && cpu_line+=" · 实时 $freq"
[[ "$CPU_LIMITS" == 1 && -n "$minmax" ]] && cpu_line+=" · 最小/最大 $minmax MHz"
[[ "$CPU_GOVERNOR" == 1 && -n "$gov" ]] && cpu_line+=" · $gov"
[[ "$CPU_POWER" == 1 && -n "$power" ]] && cpu_line+=" · $power"
printf '%s\n' "$cpu_line"
if [[ "$CPU_THREAD" == 1 ]]; then
  thread_freq=$(lscpu -e=CPU,MHZ 2>/dev/null | awk 'NR>1 {printf "%s:%sMHz%s", $1, int($2), (NR%4==1?"\n":" · ")}')
  [[ -n "$thread_freq" ]] && printf '线程频率：%s\n' "$thread_freq"
fi

if [[ "$CPU_TEMP" == 1 ]] && command -v sensors >/dev/null 2>&1; then
  sensor_data=$(timeout 3s sensors 2>/dev/null || true)
  temps=$(printf '%s\n' "$sensor_data" | awk '
    /Package id 0:|Tctl:|CPU Temp:|temp1:/ {gsub(/.*\+/, ""); gsub(/°C.*/, "°C"); if ($0 != "") { print; exit } }
  ')
  [[ -n "$temps" ]] && printf '温度：CPU %s\n' "$temps"
  if [[ "$CPU_CORE_TEMP" == 1 ]]; then
    cores=$(printf '%s\n' "$sensor_data" | awk '/Core [0-9]+:/ {gsub(/.*\+/, ""); gsub(/°C.*/, "°C"); printf "%s%s", sep, $0; sep=" · "}')
    [[ -n "$cores" ]] && printf '核心温度：%s\n' "$cores"
  fi
fi
if [[ "$IGPU_TEMP" == 1 ]] && command -v sensors >/dev/null 2>&1; then
  sensor_data=${sensor_data:-$(timeout 3s sensors 2>/dev/null || true)}
  gpu=$(printf '%s\n' "$sensor_data" | awk '/i915|amdgpu|GPU|edge:/ {if ($0 ~ /\+/) {gsub(/.*\+/, ""); gsub(/°C.*/, "°C"); print; exit}}')
  printf '核显温度：%s\n' "${gpu:-未检测到可读的核显温度}"
fi
if [[ "$FAN_SPEED" == 1 ]] && command -v sensors >/dev/null 2>&1; then
  sensor_data=${sensor_data:-$(timeout 3s sensors 2>/dev/null || true)}
  fans=$(printf '%s\n' "$sensor_data" | awk '/fan[0-9]+:/ {printf "%s%s", sep, $1 " " $2; sep=" · "}')
  printf '风扇转速：%s\n' "${fans:-未检测到风扇转速}"
fi

if [[ "$UPS_INFO" == 1 ]] && command -v apcaccess >/dev/null 2>&1; then
  ups=$(timeout 3s apcaccess status 2>/dev/null || true)
  if [[ -n "$ups" ]]; then
    status=$(printf '%s\n' "$ups" | awk -F: '/^STATUS/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
    charge=$(printf '%s\n' "$ups" | awk -F: '/^BCHARGE/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
    timeleft=$(printf '%s\n' "$ups" | awk -F: '/^TIMELEFT/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
    linev=$(printf '%s\n' "$ups" | awk -F: '/^LINEV/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
    printf 'UPS：%s%s%s%s\n' "${status:-未知}" "${charge:+ · 电池 $charge}" "${timeleft:+ · 剩余 $timeleft}" "${linev:+ · 市电 $linev}"
  fi
elif [[ "$UPS_INFO" == 1 ]]; then
  printf 'UPS：未安装 apcupsd（概要配置时可选择安装；apcaccess 由该软件包提供）\n'
fi

if [[ "$DISK_BASE" == 1 ]]; then for dev in /sys/class/block/nvme*n*; do
  [[ -e "$dev" ]] || continue
  name=$(basename "$dev")
  [[ "$name" =~ ^nvme[0-9]+n[0-9]+$ ]] || continue
  model=$(cat "$dev/device/model" 2>/dev/null | one_line)
  disk="/dev/$name"
  capacity=$(lsblk -dn -o SIZE "$disk" 2>/dev/null | one_line)
  extra="${capacity:+ · 容量 $capacity}"
  if command -v smartctl >/dev/null 2>&1; then
    smart=$(timeout 4s smartctl -a "$disk" 2>/dev/null || true)
    temp=$(printf '%s\n' "$smart" | awk -F: '/^Temperature:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
    used=$(printf '%s\n' "$smart" | awk -F: '/^Percentage Used:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
    [[ -n "$temp" ]] && extra+=" · $temp"
    [[ -n "$used" ]] && extra+=" · 已使用 $used"
    if [[ "$DISK_POWER" == 1 ]]; then hours=$(printf '%s\n' "$smart" | awk -F: '/^Power On Hours:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}'); [[ -n "$hours" ]] && extra+=" · 通电 $hours"; fi
  fi
  if [[ "$DISK_IO" == 1 ]] && command -v iostat >/dev/null 2>&1; then
    util=$(timeout 4s iostat -dx "$disk" 1 2 2>/dev/null | awk -v dev="$name" '$1 == dev {value=$NF} END {print value}')
    [[ -n "$util" ]] && extra+=" · IO 利用率 ${util}%"
  fi
  printf 'NVMe：%s%s%s\n' "$name" "${model:+ · $model}" "$extra"
done; fi
EOF
  chmod 0755 "$target"
}

overview_defaults() {
  CPU_FREQ=1; CPU_LIMITS=1; CPU_THREAD=0; CPU_GOVERNOR=1; CPU_POWER=0; CPU_TEMP=1; CPU_CORE_TEMP=0; IGPU_TEMP=0; FAN_SPEED=0
  UPS_INFO=1; DISK_BASE=1; DISK_POWER=0; DISK_IO=0; OVERVIEW_ALIGN=l
}
overview_load() {
  overview_defaults
  # The generated configuration path is fixed above.
  # shellcheck disable=SC1090
  [[ -r "$OVERVIEW_CONF" ]] && . "$OVERVIEW_CONF"
}
overview_save() {
  install -d -m 0755 /etc/pve-sensible
  cat >"$OVERVIEW_CONF" <<EOF
# Generated by pve-sensible. 0=off, 1=on.
CPU_FREQ=$CPU_FREQ
CPU_LIMITS=$CPU_LIMITS
CPU_THREAD=$CPU_THREAD
CPU_GOVERNOR=$CPU_GOVERNOR
CPU_POWER=$CPU_POWER
CPU_TEMP=$CPU_TEMP
CPU_CORE_TEMP=$CPU_CORE_TEMP
IGPU_TEMP=$IGPU_TEMP
FAN_SPEED=$FAN_SPEED
UPS_INFO=$UPS_INFO
DISK_BASE=$DISK_BASE
DISK_POWER=$DISK_POWER
DISK_IO=$DISK_IO
OVERVIEW_ALIGN=$OVERVIEW_ALIGN
EOF
  chmod 0644 "$OVERVIEW_CONF"
}
mark() { [[ "$1" == 1 ]] && printf '[*]' || printf '[ ]'; }
toggle() { [[ "$1" == 1 ]] && printf 0 || printf 1; }
overview_preset() {
  case "$1" in
    o) CPU_FREQ=1; CPU_LIMITS=1; CPU_THREAD=1; CPU_GOVERNOR=1; CPU_POWER=1; CPU_TEMP=1; CPU_CORE_TEMP=1; IGPU_TEMP=1; FAN_SPEED=1; UPS_INFO=0; DISK_BASE=1; DISK_POWER=1; DISK_IO=1; OVERVIEW_ALIGN=r ;;
    p) CPU_FREQ=1; CPU_LIMITS=1; CPU_THREAD=0; CPU_GOVERNOR=1; CPU_POWER=0; CPU_TEMP=1; CPU_CORE_TEMP=0; IGPU_TEMP=0; FAN_SPEED=0; UPS_INFO=1; DISK_BASE=1; DISK_POWER=0; DISK_IO=0; OVERVIEW_ALIGN=l ;;
    q) CPU_FREQ=1; CPU_LIMITS=0; CPU_THREAD=0; CPU_GOVERNOR=0; CPU_POWER=0; CPU_TEMP=1; CPU_CORE_TEMP=0; IGPU_TEMP=0; FAN_SPEED=0; UPS_INFO=1; DISK_BASE=1; DISK_POWER=0; DISK_IO=0; OVERVIEW_ALIGN=l ;;
  esac
}
overview_selected() {
  local items=()
  [[ "$CPU_FREQ" == 1 ]] && items+=('CPU 实时主频')
  [[ "$CPU_LIMITS" == 1 ]] && items+=('CPU 最小/最大主频')
  [[ "$CPU_THREAD" == 1 ]] && items+=('CPU 线程主频')
  [[ "$CPU_GOVERNOR" == 1 ]] && items+=('CPU 工作模式')
  [[ "$CPU_POWER" == 1 ]] && items+=('CPU 功率')
  [[ "$CPU_TEMP" == 1 ]] && items+=('CPU 温度')
  [[ "$CPU_CORE_TEMP" == 1 ]] && items+=('CPU 核心温度')
  [[ "$IGPU_TEMP" == 1 ]] && items+=('核显温度')
  [[ "$FAN_SPEED" == 1 ]] && items+=('风扇转速')
  [[ "$UPS_INFO" == 1 ]] && items+=('UPS 信息')
  [[ "$DISK_BASE" == 1 ]] && items+=('NVMe 基础/寿命')
  [[ "$DISK_POWER" == 1 ]] && items+=('NVMe 通电信息')
  [[ "$DISK_IO" == 1 ]] && items+=('NVMe IO 信息')
  (IFS='、'; printf '%s' "${items[*]}")
}
overview_profile_mark() {
  local profile="$1"
  case "$profile" in
    o) [[ "$CPU_FREQ$CPU_LIMITS$CPU_THREAD$CPU_GOVERNOR$CPU_POWER$CPU_TEMP$CPU_CORE_TEMP$IGPU_TEMP$FAN_SPEED$UPS_INFO$DISK_BASE$DISK_POWER$DISK_IO$OVERVIEW_ALIGN" == 1111111110111r ]] && printf '[*]' || printf '[ ]' ;;
    p) [[ "$CPU_FREQ$CPU_LIMITS$CPU_THREAD$CPU_GOVERNOR$CPU_POWER$CPU_TEMP$CPU_CORE_TEMP$IGPU_TEMP$FAN_SPEED$UPS_INFO$DISK_BASE$DISK_POWER$DISK_IO$OVERVIEW_ALIGN" == 1101010001100l ]] && printf '[*]' || printf '[ ]' ;;
    q) [[ "$CPU_FREQ$CPU_LIMITS$CPU_THREAD$CPU_GOVERNOR$CPU_POWER$CPU_TEMP$CPU_CORE_TEMP$IGPU_TEMP$FAN_SPEED$UPS_INFO$DISK_BASE$DISK_POWER$DISK_IO$OVERVIEW_ALIGN" == 1000010001100l ]] && printf '[*]' || printf '[ ]' ;;
  esac
}
configure_overview() {
  local choices c
  overview_load
  while true; do
    cat <<EOF

概要信息定制向导（输入多个编号可逐项切换，例如：0259ac）
$(mark "$CPU_FREQ") 0) CPU 实时主频
$(mark "$CPU_LIMITS") 1) CPU 最小及最大主频
$(mark "$CPU_THREAD") 2) CPU 线程主频
$(mark "$CPU_GOVERNOR") 3) CPU 工作模式
$(mark "$CPU_POWER") 4) CPU 功率（需要 turbostat）
$(mark "$CPU_TEMP") 5) CPU 温度（需要 lm-sensors）
$(mark "$CPU_CORE_TEMP") 6) CPU 核心温度（核心多时会较长）
$(mark "$IGPU_TEMP") 7) 核显温度（仅在传感器可读取时显示）
$(mark "$FAN_SPEED") 8) 风扇转速（可能需额外传感器驱动）
$(mark "$UPS_INFO") 9) UPS 信息（需要 apcupsd / apcaccess）
$(mark "$DISK_BASE") a) NVMe 基础信息与寿命（需要 smartmontools）
$(mark "$DISK_POWER") b) NVMe 通电信息（依赖 a）
$(mark "$DISK_IO") c) NVMe IO 信息（依赖 a）

$( [[ "$OVERVIEW_ALIGN" == l ]] && printf '[*]' || printf '[ ]' ) l) 概要信息：居左显示
$( [[ "$OVERVIEW_ALIGN" == r ]] && printf '[*]' || printf '[ ]' ) r) 概要信息：居右显示
$( [[ "$OVERVIEW_ALIGN" == m ]] && printf '[*]' || printf '[ ]' ) m) 概要信息：居中显示
$( [[ "$OVERVIEW_ALIGN" == j ]] && printf '[*]' || printf '[ ]' ) j) 概要信息：平铺显示

$(overview_profile_mark o) o) 高大全：全部启用（含功率、核心温度、通电、IO）
$(overview_profile_mark p) p) 精简：实时/最小最大频率、工作模式、CPU 温度、UPS、NVMe 基础
$(overview_profile_mark q) q) 极简：实时频率、CPU 温度、UPS、NVMe 基础
[ ] x) 恢复默认精简方案       [ ] s) 跳过本次修改
EOF
    read -r -p '输入编号切换；直接按 Enter 应用：' choices
    if [[ -z "$choices" ]]; then
      [[ "$DISK_BASE" == 0 ]] && { DISK_POWER=0; DISK_IO=0; }
      printf '\n本次概要配置：%s\n' "$(overview_selected)"
      install_overview_dependencies || { info '依赖未就绪，已取消本次概要修改。'; return 1; }
      overview_save
      return 0
    fi
    [[ "$choices" == s ]] && return 1
    [[ "$choices" == o || "$choices" == p || "$choices" == q ]] && overview_preset "$choices"
    [[ "$choices" == x ]] && overview_defaults
    for ((i=0; i<${#choices}; i++)); do
      c=${choices:i:1}
      case "$c" in
        0) CPU_FREQ=$(toggle "$CPU_FREQ") ;; 1) CPU_LIMITS=$(toggle "$CPU_LIMITS") ;; 2) CPU_THREAD=$(toggle "$CPU_THREAD") ;;
        3) CPU_GOVERNOR=$(toggle "$CPU_GOVERNOR") ;; 4) CPU_POWER=$(toggle "$CPU_POWER") ;;
        5) CPU_TEMP=$(toggle "$CPU_TEMP") ;; 6) CPU_CORE_TEMP=$(toggle "$CPU_CORE_TEMP") ;; 7) IGPU_TEMP=$(toggle "$IGPU_TEMP") ;; 8) FAN_SPEED=$(toggle "$FAN_SPEED") ;;
        9) UPS_INFO=$(toggle "$UPS_INFO") ;; a) DISK_BASE=$(toggle "$DISK_BASE") ;;
        b) DISK_POWER=$(toggle "$DISK_POWER") ;; c) DISK_IO=$(toggle "$DISK_IO") ;; l|r|m|j) OVERVIEW_ALIGN="$c" ;;
      esac
    done
    [[ "$DISK_BASE" == 0 ]] && { DISK_POWER=0; DISK_IO=0; }
  done
}

install_overview_dependencies() {
  local packages=() package
  if [[ "$CPU_POWER" == 1 ]] && ! command -v turbostat >/dev/null 2>&1; then packages+=(linux-cpupower); fi
  if [[ "$CPU_TEMP" == 1 || "$CPU_CORE_TEMP" == 1 || "$IGPU_TEMP" == 1 || "$FAN_SPEED" == 1 ]] && ! command -v sensors >/dev/null 2>&1; then packages+=(lm-sensors); fi
  if [[ "$DISK_BASE" == 1 ]] && ! command -v smartctl >/dev/null 2>&1; then packages+=(smartmontools); fi
  if [[ "$DISK_IO" == 1 ]] && ! command -v iostat >/dev/null 2>&1; then packages+=(sysstat); fi
  if [[ "$UPS_INFO" == 1 ]] && ! command -v apcaccess >/dev/null 2>&1; then packages+=(apcupsd); fi
  ((${#packages[@]} == 0)) && return 0
  info "概要功能缺少以下 Debian 软件包：${packages[*]}"
  confirm '现在安装这些依赖吗？取消将不会修改概要页面。' || return 1
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  for package in "${packages[@]}"; do
    case "$package" in
      linux-cpupower) command -v turbostat >/dev/null || die '已安装 linux-cpupower，但未找到 turbostat。' ;;
      lm-sensors) command -v sensors >/dev/null || die '已安装 lm-sensors，但未找到 sensors。' ;;
      smartmontools) command -v smartctl >/dev/null || die '已安装 smartmontools，但未找到 smartctl。' ;;
      sysstat) command -v iostat >/dev/null || die '已安装 sysstat，但未找到 iostat。' ;;
      apcupsd) command -v apcaccess >/dev/null || die '已安装 apcupsd，但未找到 apcaccess。' ;;
    esac
  done
}

write_rollback_helper() {
  install -d -m 0755 "$LIB_DIR"
  cat >"$ROLLBACK_HELPER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
backup_dir=${1:?backup directory required}
for name in Nodes.pm pvemanagerlib.js proxmoxlib.js; do
  [[ -f "$backup_dir/$name" ]] || continue
  case "$name" in
    Nodes.pm) target=/usr/share/perl5/PVE/API2/Nodes.pm ;;
    pvemanagerlib.js) target=/usr/share/pve-manager/js/pvemanagerlib.js ;;
    proxmoxlib.js) target=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js ;;
  esac
  cp -a -- "$backup_dir/$name" "$target"
done
systemctl restart pveproxy
logger -t pve-sensible 'UI files automatically restored from rollback backup'
EOF
  chmod 0755 "$ROLLBACK_HELPER"
}

schedule_ui_rollback() {
  local purpose="$1"
  write_rollback_helper
  CURRENT_ROLLBACK_UNIT="${ROLLBACK_UNIT}-$(date +%s%N)-$$-$RANDOM"
  systemd-run --quiet --unit="$CURRENT_ROLLBACK_UNIT" --on-active=3m "$ROLLBACK_HELPER" "$CURRENT_BACKUP_DIR"
  info "已启用 3 分钟自动回退保护（$purpose）。"
}

keep_ui_changes() {
  local answer=''
  info '请在另一个浏览器标签页打开 PVE，并强制刷新页面。'
  info '确认概要页或登录页正常后，请在 180 秒内输入 KEEP 保留本次修改。'
  read -r -t 180 -p '确认：' answer || true
  if [[ "$answer" == KEEP ]]; then
    systemctl stop "$CURRENT_ROLLBACK_UNIT.timer" "$CURRENT_ROLLBACK_UNIT.service" 2>/dev/null || true
    info '已保留修改，自动回退已取消。'
  else
    systemctl stop "$CURRENT_ROLLBACK_UNIT.timer" "$CURRENT_ROLLBACK_UNIT.service" 2>/dev/null || true
    "$ROLLBACK_HELPER" "$CURRENT_BACKUP_DIR"
    info '未收到 KEEP 确认；原始 UI 文件已恢复。'
  fi
}

restart_and_verify_pveproxy() {
  local _attempt
  systemctl restart pveproxy
  systemctl is-active --quiet pveproxy || { "$ROLLBACK_HELPER" "$CURRENT_BACKUP_DIR"; die 'pveproxy 未能启动，原始文件已恢复。'; }
  if command -v curl >/dev/null 2>&1; then
    for _attempt in {1..12}; do
      if curl -ksf --connect-timeout 2 https://127.0.0.1:8006/api2/json/version >/dev/null; then return 0; fi
      sleep 1
    done
    "$ROLLBACK_HELPER" "$CURRENT_BACKUP_DIR"
    die 'pveproxy 虽在运行，但本机 8006 API 无法访问；原始文件已恢复。'
  fi
  info '未安装 curl，已完成服务状态校验；仍需在 KEEP 前由浏览器确认页面。'
}

restore_latest_ui() {
  local latest
  latest=$(find "$STATE_DIR/backups" -mindepth 2 -maxdepth 2 -type f \( -name Nodes.pm -o -name pvemanagerlib.js -o -name proxmoxlib.js \) -printf '%h\n' 2>/dev/null | sort -u | tail -n1 || true)
  [[ -n "$latest" ]] || die '未找到可用于恢复的 PVE UI 备份。'
  write_rollback_helper
  "$ROLLBACK_HELPER" "$latest"
  info "已从以下备份恢复 UI 文件：$latest"
}

validate_restore_target() {
  if [[ -n "${PVE_SENSIBLE_TEST_ROOT:-}" && "$1" == "$PVE_SENSIBLE_TEST_ROOT/"* ]]; then
    return 0
  fi
  case "$1" in
    /usr/share/perl5/PVE/API2/Nodes.pm|/usr/share/pve-manager/js/pvemanagerlib.js|/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js|/usr/share/perl5/PVE/APLInfo.pm|/etc/network/interfaces|/etc/default/grub|/etc/modules|/etc/apt/sources.list.d/debian.sources|/etc/apt/sources.list.d/pve-no-subscription.sources|/etc/apt/sources.list.d/pve-enterprise.sources|/etc/apt/sources.list.d/ceph.sources) return 0 ;;
    *) return 1 ;;
  esac
}

restore_recorded_backup() {
  local dir="$1" state target saved manifest="$1/manifest.tsv"
  [[ -f "$manifest" ]] || die "备份缺少恢复清单：$dir"
  while IFS=$'\t' read -r state target; do
    validate_restore_target "$target" || die "备份清单包含非预期路径，拒绝恢复：$target"
    saved="$dir/$(basename "$target")"
    case "$state" in
      present) [[ -f "$saved" ]] || die "备份文件缺失：$saved"; cp -a -- "$saved" "$target" ;;
      absent) rm -f -- "$target" ;;
      *) die "备份清单状态无效：$state" ;;
    esac
  done <"$manifest"
}

latest_backup_by_label() {
  local label="$1"
  find "$STATE_DIR/backups" -mindepth 1 -maxdepth 1 -type d -name "*-$label" -printf '%p\n' 2>/dev/null | sort | tail -n1
}

restore_backup_menu() {
  local choice dir
  cat <<'EOF'

恢复备份：
  1) 最近一次 PVE UI / 订阅弹窗备份
  2) 最近一次软件源备份
  3) 最近一次 IPv6 网络配置备份（不重启网络）
  4) 最近一次 CT 模板源备份
  5) 最近一次 IOMMU 启动配置备份
  0) 返回
EOF
  read -r -p '请选择：' choice
  case "$choice" in
    1) restore_latest_ui; return ;;
    2) dir=$(latest_backup_by_label sources) ;;
    3) dir=$(latest_backup_by_label ipv6) ;;
    4) dir=$(latest_backup_by_label ct-template) ;;
    5) dir=$(latest_backup_by_label iommu) ;;
    0) return ;;
    *) printf '无效选择。\n'; return ;;
  esac
  [[ -n "$dir" ]] || die '未找到对应类型的备份。'
  confirm "确认从 $dir 恢复吗？" || return 0
  restore_recorded_backup "$dir"
  case "$choice" in
    2) apt-get update || info '原软件源已恢复，但当前 apt 更新仍失败，请检查网络或其他第三方源。' ;;
    3) info '网络文件已恢复；为避免 SSH 断线，未重启网络。' ;;
    4) pveam update || info 'APLInfo.pm 已恢复，但模板列表更新失败。' ;;
    5)
      if ! update-initramfs -u -k all || ! update-grub; then
        die '配置文件已恢复，但重新生成启动文件失败，请勿重启。'
      fi
      ;;
  esac
  info "恢复完成：$dir"
}

legacy_overview_detected() {
  local nodes="${1:-$NODES_PM}" manager="${2:-$MANAGER_JS}"
  # The literal dollar sign identifies legacy Perl variables.
  # shellcheck disable=SC2016
  grep -Eq 'my[[:space:]]+\$(cpumodes|cpupowers|cpufreqs)|turbostat[^;]*PkgWatt' "$nodes" ||
    grep -Eq "textField:[[:space:]]*['\"](cpumode|cpupower|cpufreqs|cputemp|coretemp|nvme|upsinfo)['\"]" "$manager"
}

extract_pristine_pve_manager() {
  local dest="$1" owner_js owner_nodes version deb='' candidate cache="${PVE_SENSIBLE_APT_CACHE:-/var/cache/apt/archives}"
  owner_nodes=$(dpkg-query -S "$NODES_PM" 2>/dev/null | head -n1 | cut -d: -f1)
  owner_js=$(dpkg-query -S "$MANAGER_JS" 2>/dev/null | head -n1 | cut -d: -f1)
  [[ "$owner_nodes" == pve-manager && "$owner_js" == pve-manager ]] || die '无法确认两个概要文件均属于 pve-manager 软件包，拒绝自动迁移。'
  version=$(dpkg-query -W -f='${Version}' pve-manager 2>/dev/null)
  [[ -n "$version" ]] || die '无法读取当前 pve-manager 精确版本。'

  for candidate in "$cache"/pve-manager_*.deb; do
    [[ -f "$candidate" ]] || continue
    if [[ "$(dpkg-deb -f "$candidate" Version 2>/dev/null || true)" == "$version" ]]; then
      deb="$candidate"
      break
    fi
  done
  if [[ -z "$deb" ]]; then
    info "正在下载当前已安装的精确版本 pve-manager=$version（仅下载，不安装）。"
    (cd "$dest" && apt-get download "pve-manager=$version") || die '无法下载当前已安装的 pve-manager 精确版本；未修改任何 UI 文件。'
    for candidate in "$dest"/pve-manager_*.deb; do
      [[ -f "$candidate" ]] || continue
      if [[ "$(dpkg-deb -f "$candidate" Version 2>/dev/null || true)" == "$version" ]]; then deb="$candidate"; break; fi
    done
  fi
  [[ -f "$deb" ]] || die '没有找到与当前安装版本完全一致的 pve-manager 安装包；未修改任何 UI 文件。'
  dpkg-deb -x "$deb" "$dest/root" || die '无法解压 pve-manager 安装包；未修改任何 UI 文件。'
  [[ -f "$dest/root$NODES_PM" && -f "$dest/root$MANAGER_JS" ]] || die '安装包内缺少概要文件；未修改任何 UI 文件。'
  perl -c "$dest/root$NODES_PM" >/dev/null || die '安装包内 Nodes.pm 校验失败；未修改任何 UI 文件。'
  grep -q "textField:[[:space:]]*['\"]pveversion['\"]" "$dest/root$MANAGER_JS" || die '安装包内 pvemanagerlib.js 缺少 PVE 9 概要锚点；未修改任何 UI 文件。'
}

preflight_overview_compatibility() {
  local node_source="${1:-$NODES_PM}" js_source="${2:-$MANAGER_JS}" node_test js_test block
  node_test=$(mktemp) || die '无法创建概要信息兼容性测试文件。'
  js_test=$(mktemp) || { rm -f "$node_test"; die '无法创建概要信息兼容性测试文件。'; }
  block=$(mktemp) || { rm -f "$node_test" "$js_test"; die '无法创建概要信息兼容性测试文件。'; }
  cp -- "$node_source" "$node_test"
  cp -- "$js_source" "$js_test"
  if ! grep -q 'PVE_SENSIBLE_OVERVIEW' "$node_test"; then
    if ! insert_nodes_summary "$node_test" 2>/dev/null || ! grep -q 'PVE_SENSIBLE_OVERVIEW' "$node_test"; then
      rm -f "$node_test" "$js_test" "$block"
      die '当前 PVE 的 Nodes.pm 与脚本不兼容；未修改任何文件。请提交 pveversion 附近的代码后再适配。'
    fi
  fi
  if grep -q 'PVE_SENSIBLE_OVERVIEW' "$js_test"; then
    if ! update_overview_alignment "$js_test"; then
      rm -f "$node_test" "$js_test" "$block"
      die '现有 pve-sensible 概要区块不完整；未修改任何文件。请先从菜单 6 恢复 UI 备份。'
    fi
  else
    write_overview_js_block "$block"
    if ! insert_after_pveversion "$js_test" "$block" || ! grep -q 'PVE_SENSIBLE_OVERVIEW' "$js_test"; then
      rm -f "$node_test" "$js_test" "$block"
      die '当前 PVE 的 pvemanagerlib.js 与脚本不兼容；未修改任何文件。请提交 pveversion 概要项附近的代码后再适配。'
    fi
  fi
  rm -f "$node_test" "$js_test" "$block"
  info '概要信息兼容性预检通过：实际文件可完成后端与前端插入。'
}

insert_nodes_summary() {
  local target="$1"
  perl -0777 -i -pe 's{(\$res->\{pveversion\}\s*=\s*[^;]+;)}{$1\n\t# PVE_SENSIBLE_OVERVIEW\n\t$res->{pve_sensible_summary} = qx(/usr/local/lib/pve-sensible/summary.sh);\n} or die "pveversion assignment not found\n"' "$target"
}

write_overview_js_block() {
  local target="$1" align
  case "$OVERVIEW_ALIGN" in l) align=left ;; r) align=right ;; m) align=center ;; j) align=justify ;; esac
  cat >"$target" <<EOF
        // PVE_SENSIBLE_OVERVIEW_BEGIN
        {
            itemId: 'pve-sensible-summary',
            colspan: 2,
            printBar: false,
            title: gettext('硬件状态'),
            textField: 'pve_sensible_summary',
            style: { textAlign: '$align' },
            renderer: function(value) {
                return Ext.htmlEncode(value || '').replace(/\\n/g, '<br>');
            },
        },
        // PVE_SENSIBLE_OVERVIEW_END
EOF
}

update_overview_alignment() {
  local target="$1" align marker_line end_line count
  case "$OVERVIEW_ALIGN" in l) align=left ;; r) align=right ;; m) align=center ;; j) align=justify ;; *) return 1 ;; esac
  count=$(grep -c 'PVE_SENSIBLE_OVERVIEW' "$target" || true)
  # New blocks have BEGIN+END; old blocks have one marker. Both are supported.
  [[ "$count" == 1 || "$count" == 2 ]] || return 1
  marker_line=$(grep -n -m1 'PVE_SENSIBLE_OVERVIEW' "$target" | cut -d: -f1)
  [[ "$marker_line" =~ ^[0-9]+$ ]] || return 1
  end_line=$((marker_line + 18))
  count=$(sed -n "${marker_line},${end_line}p" "$target" | grep -Ec "textAlign:[[:space:]]*'(left|right|center|justify)'" || true)
  [[ "$count" == 1 ]] || return 1
  sed -i "${marker_line},${end_line}s/textAlign:[[:space:]]*'(left\|right\|center\|justify)'/textAlign: '$align'/" "$target"
  sed -n "${marker_line},${end_line}p" "$target" | grep -q "textAlign: '$align'"
}

insert_after_pveversion() {
  local target="$1" block="$2" line
  # Same anchoring approach as pve-diy: locate pveversion, then its object end.
  line=$(awk '/textField:[[:space:]]*[\047"]pveversion[\047"]/{found=1} found && /^[[:space:]]*},[[:space:]]*$/{print NR; exit}' "$target")
  [[ "$line" =~ ^[0-9]+$ ]] || return 1
  sed -i "${line}r $block" "$target"
}

apply_overview() {
  local pristine_dir='' node_source="$NODES_PM" js_source="$MANAGER_JS" answer block
  [[ -f "$NODES_PM" && -f "$MANAGER_JS" ]] || die '未找到 PVE 前端文件。'
  overview_load
  if legacy_overview_detected "$NODES_PM" "$MANAGER_JS"; then
    info '检测到旧版 pve_source 概要代码。为防止字段重复，不能直接叠加新补丁。'
    info '迁移会先从当前 pve-manager 精确版本安装包提取原版文件；不会重装软件包。旧文件仍受 3 分钟自动回退保护。'
    read -r -p '确认迁移请输入 MIGRATE：' answer
    [[ "$answer" == MIGRATE ]] || { info '已取消；未修改任何文件。'; return 0; }
    pristine_dir=$(mktemp -d) || die '无法创建原版文件提取目录。'
    extract_pristine_pve_manager "$pristine_dir"
    node_source="$pristine_dir/root$NODES_PM"
    js_source="$pristine_dir/root$MANAGER_JS"
  fi
  preflight_overview_compatibility "$node_source" "$js_source"
  configure_overview || { [[ -z "$pristine_dir" ]] || rm -rf -- "$pristine_dir"; return 0; }
  begin_transaction overview
  backup "$NODES_PM"; backup "$MANAGER_JS"
  schedule_ui_rollback 'overview installation'
  if [[ -n "$pristine_dir" ]]; then
    cp --preserve=mode,timestamps -- "$node_source" "$NODES_PM"
    cp --preserve=mode,timestamps -- "$js_source" "$MANAGER_JS"
    rm -rf -- "$pristine_dir"
  fi
  write_summary_helper "$SUMMARY_HELPER"

  if ! grep -q 'PVE_SENSIBLE_OVERVIEW' "$NODES_PM"; then
    if ! insert_nodes_summary "$NODES_PM"; then
      "$ROLLBACK_HELPER" "$CURRENT_BACKUP_DIR"
      die 'Nodes.pm 插入失败，原始文件已恢复。'
    fi
  fi
  if grep -q 'PVE_SENSIBLE_OVERVIEW' "$MANAGER_JS"; then
    if ! update_overview_alignment "$MANAGER_JS"; then
      "$ROLLBACK_HELPER" "$CURRENT_BACKUP_DIR"
      die '已有概要区块的排版更新失败，原始文件已恢复。'
    fi
  else
    block=$(mktemp) || { "$ROLLBACK_HELPER" "$CURRENT_BACKUP_DIR"; die '无法创建概要信息前端区块。'; }
    write_overview_js_block "$block"
    if ! insert_after_pveversion "$MANAGER_JS" "$block"; then
      rm -f "$block"; "$ROLLBACK_HELPER" "$CURRENT_BACKUP_DIR"; die 'PVE_SENSIBLE: pveversion 插入点未找到，原始文件已恢复。'
    fi
    rm -f "$block"
  fi
  if ! perl -c "$NODES_PM" >/dev/null; then "$ROLLBACK_HELPER" "$CURRENT_BACKUP_DIR"; die 'Perl 校验失败，原始文件已恢复。'; fi
  restart_and_verify_pveproxy
  keep_ui_changes
}

set_ipv6_slaac() {
  local file=/etc/network/interfaces test_file
  [[ -f "$file" ]] || die "$file 不存在。"
  grep -qE '^[[:space:]]*iface[[:space:]]+vmbr0[[:space:]]+inet6[[:space:]]+' "$file" && die 'vmbr0 已有 inet6 配置，不能叠加本 SLAAC 方案。'
  if grep -Eq 'net\.ipv6\.conf\.vmbr0\.accept_ra[=[:space:]]+2|/proc/sys/net/ipv6/conf/vmbr0/accept_ra' "$file"; then
    sysctl -qw net.ipv6.conf.vmbr0.accept_ra=2
    info '已检测到 vmbr0 的 accept_ra=2 持久化配置，未重复写入。'
    ip -6 addr show dev vmbr0 scope global || true
    return 0
  fi
  test_file=$(mktemp) || die '无法创建 IPv6 配置预检文件。'
  cp -- "$file" "$test_file"
  if ! insert_ipv6_slaac "$test_file"; then
    rm -f "$test_file"
    die '未能唯一定位 iface vmbr0 inet 配置段；未修改网络文件。'
  fi
  rm -f "$test_file"
  begin_transaction ipv6
  backup "$file"
  if ! insert_ipv6_slaac "$file"; then
    restore_source_transaction "$CURRENT_BACKUP_DIR" "$file"
    die 'IPv6 配置写入失败，原网络文件已恢复。'
  fi
  sysctl -qw net.ipv6.conf.vmbr0.accept_ra=2
  info '已在 vmbr0 配置段加入 accept_ra=2；未重启网络，当前内核参数已立即生效。'
  ip -6 addr show dev vmbr0 scope global || true
}

insert_ipv6_slaac() {
  local target="$1" count
  grep -Eq 'net\.ipv6\.conf\.vmbr0\.accept_ra[=[:space:]]+2|/proc/sys/net/ipv6/conf/vmbr0/accept_ra' "$target" && return 0
  count=$(grep -Ec '^[[:space:]]*iface[[:space:]]+vmbr0[[:space:]]+inet[[:space:]]+' "$target" || true)
  [[ "$count" == 1 ]] || return 1
  sed -i '/^[[:space:]]*iface[[:space:]]\+vmbr0[[:space:]]\+inet[[:space:]]\+/a\    post-up sysctl -qw net.ipv6.conf.vmbr0.accept_ra=2 # PVE_SENSIBLE_SLAAC' "$target"
  grep -q 'PVE_SENSIBLE_SLAAC' "$target"
}

choose_mirror() {
  local mirror
  cat <<'EOF'

请选择镜像：
  1) 清华 TUNA
  2) 中科大 USTC
  3) 官方源
  0) 取消
EOF
  read -r -p '请选择：' mirror
  case "$mirror" in
    1) MIRROR_NAME='清华 TUNA'; DEBIAN_URI=https://mirrors.tuna.tsinghua.edu.cn/debian; SECURITY_URI=https://mirrors.tuna.tsinghua.edu.cn/debian-security; PVE_URI=https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve; CEPH_URI=https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/ceph-squid; CT_URI=https://mirrors.tuna.tsinghua.edu.cn/proxmox ;;
    2) MIRROR_NAME='中科大 USTC'; DEBIAN_URI=https://mirrors.ustc.edu.cn/debian; SECURITY_URI=https://mirrors.ustc.edu.cn/debian-security; PVE_URI=https://mirrors.ustc.edu.cn/proxmox/debian/pve; CEPH_URI=https://mirrors.ustc.edu.cn/proxmox/debian/ceph-squid; CT_URI=https://mirrors.ustc.edu.cn/proxmox ;;
    3) MIRROR_NAME='官方源'; DEBIAN_URI=https://deb.debian.org/debian; SECURITY_URI=https://security.debian.org/debian-security; PVE_URI=http://download.proxmox.com/debian/pve; CEPH_URI=http://download.proxmox.com/debian/ceph-squid; CT_URI=http://download.proxmox.com ;;
    0) return 1 ;;
    *) printf '无效选择。\n'; return 1 ;;
  esac
}

restore_source_transaction() {
  local dir="$1"; shift
  local target name
  for target in "$@"; do
    name=$(basename "$target")
    rm -f -- "$target"
    [[ -f "$dir/$name" ]] && cp -a -- "$dir/$name" "$target"
  done
}

validate_apt_or_restore() {
  local dir="$1"; shift
  if ! apt-get update; then
    info 'apt 更新验证失败，正在自动恢复本次变更的源文件。'
    restore_source_transaction "$dir" "$@"
    die '软件源验证失败；已恢复修改前的源配置。'
  fi
}

write_debian_source() {
  local debian="$1"
  cat >"$debian" <<EOF
Types: deb
URIs: $DEBIAN_URI
Suites: trixie trixie-updates trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: $SECURITY_URI
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
}

write_pve_sources() {
  local pve="$1" enterprise="$2"
  cat >"$pve" <<EOF
Types: deb
URIs: $PVE_URI
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  [[ -f "$enterprise" ]] && sed -i 's/^\([^#]\)/# \1/' "$enterprise"
}

write_ceph_source() {
  local ceph="$1"
  cat >"$ceph" <<EOF
Types: deb
URIs: $CEPH_URI
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
}

set_ct_template_source() {
  local apl=/usr/share/perl5/PVE/APLInfo.pm
  [[ -f "$apl" ]] || die "未找到 $apl。"
  choose_mirror || return 0
  confirm "将 CT 模板下载地址改为 $MIRROR_NAME 吗？PVE 软件包更新可能覆盖此修改。" || return 0
  begin_transaction ct-template
  backup "$apl"
  if ! replace_ct_source "$apl" "$CT_URI"; then
    restore_source_transaction "$CURRENT_BACKUP_DIR" "$apl"
    die 'CT 模板源定位失败；原文件已恢复。'
  fi
  grep -qF "$CT_URI" "$apl" || { restore_source_transaction "$CURRENT_BACKUP_DIR" "$apl"; die 'CT 模板源定位失败；原文件已恢复。'; }
  if ! pveam update; then
    restore_source_transaction "$CURRENT_BACKUP_DIR" "$apl"
    pveam update >/dev/null 2>&1 || true
    die 'CT 模板列表更新失败，APLInfo.pm 已恢复。'
  fi
  info "CT 模板源已改为 $MIRROR_NAME，模板列表更新成功。PVE 更新后可通过备份记录重新应用。"
}

replace_ct_source() {
  local target="$1" replacement="$2"
  CT_REPLACEMENT="$replacement" perl -0777 -i -pe 's{https?://(?:download\.proxmox\.com|mirrors\.tuna\.tsinghua\.edu\.cn/proxmox|mirrors\.ustc\.edu\.cn/proxmox)(?=/|[\x27\"])}{$ENV{CT_REPLACEMENT}}g' "$target"
}

set_sources() {
  local codename action debian=/etc/apt/sources.list.d/debian.sources pve=/etc/apt/sources.list.d/pve-no-subscription.sources enterprise=/etc/apt/sources.list.d/pve-enterprise.sources ceph=/etc/apt/sources.list.d/ceph.sources
  codename=$(. /etc/os-release; printf '%s' "$VERSION_CODENAME")
  [[ "$codename" == trixie ]] || die "PVE 9 预期 Debian trixie，当前为：$codename"
  cat <<'EOF'

软件源配置（每项独立备份；apt 更新验证失败将自动恢复）：
  1) Debian 软件源
  2) PVE：关闭企业源并配置无订阅源
  3) Ceph 无订阅源（仅在已有 Ceph 配置或已安装 Ceph 时可用）
  4) CT 模板下载源（修改 APLInfo.pm；PVE 更新可能覆盖）
  5) 常用组合：Debian + PVE 无订阅源 + 已存在的 Ceph 源
  0) 返回
EOF
  read -r -p '请选择：' action
  [[ "$action" == 0 ]] && return 0
  [[ "$action" =~ ^[1-5]$ ]] || { printf '无效选择。\n'; return 0; }
  [[ "$action" == 4 ]] && { set_ct_template_source; return; }
  if [[ "$action" == 3 || "$action" == 5 ]]; then
    if [[ ! -f "$ceph" ]] && ! dpkg-query -W -f='${Status}' 'ceph*' 2>/dev/null | grep -q 'install ok installed'; then
      [[ "$action" == 3 ]] && die '未检测到 Ceph 配置或已安装的 Ceph 软件包，拒绝新增 Ceph 源。'
      info '未检测到 Ceph，常用组合将跳过 Ceph 源。'
    fi
  fi
  choose_mirror || return 0
  confirm "确认将所选项目切换为 $MIRROR_NAME，并在 apt 更新失败时自动恢复吗？" || return 0
  begin_transaction sources
  case "$action" in
    1) backup "$debian"; write_debian_source "$debian"; validate_apt_or_restore "$CURRENT_BACKUP_DIR" "$debian" ;;
    2) backup "$pve"; backup "$enterprise"; write_pve_sources "$pve" "$enterprise"; validate_apt_or_restore "$CURRENT_BACKUP_DIR" "$pve" "$enterprise" ;;
    3) backup "$ceph"; write_ceph_source "$ceph"; validate_apt_or_restore "$CURRENT_BACKUP_DIR" "$ceph" ;;
    5)
      backup "$debian"; backup "$pve"; backup "$enterprise"
      write_debian_source "$debian"; write_pve_sources "$pve" "$enterprise"
      if [[ -f "$ceph" ]] || dpkg-query -W -f='${Status}' 'ceph*' 2>/dev/null | grep -q 'install ok installed'; then backup "$ceph"; write_ceph_source "$ceph"; validate_apt_or_restore "$CURRENT_BACKUP_DIR" "$debian" "$pve" "$enterprise" "$ceph"; else validate_apt_or_restore "$CURRENT_BACKUP_DIR" "$debian" "$pve" "$enterprise"; fi ;;
  esac
  info "软件源已通过 apt 更新验证。本次备份：$CURRENT_BACKUP_DIR"
}

disable_subscription_popup() {
  local test_file
  [[ -f "$TOOLKIT_JS" ]] || die '未找到 Proxmox 前端工具文件。'
  if subscription_popup_disabled_in_file "$TOOLKIT_JS"; then info '已检测到订阅弹窗禁用补丁，未重复修改。'; return; fi
  test_file=$(mktemp) || die '无法创建订阅弹窗兼容性测试文件。'
  cp -- "$TOOLKIT_JS" "$test_file"
  if ! disable_subscription_in_file "$test_file" || ! grep -q 'PVE_SENSIBLE_NO_SUBSCRIPTION' "$test_file"; then
    rm -f "$test_file"
    die '当前 PVE 前端的订阅弹窗定位不兼容；未修改任何文件。'
  fi
  rm -f "$test_file"
  begin_transaction subscription-popup
  backup "$TOOLKIT_JS"
  schedule_ui_rollback 'subscription-popup patch'
  if ! disable_subscription_in_file "$TOOLKIT_JS" || ! grep -q 'PVE_SENSIBLE_NO_SUBSCRIPTION' "$TOOLKIT_JS"; then
    "$ROLLBACK_HELPER" "$CURRENT_BACKUP_DIR"
    die '订阅弹窗补丁写入失败，原始文件已恢复。'
  fi
  restart_and_verify_pveproxy
  info '登录订阅弹窗补丁已应用。PVE 软件包升级后可能会被覆盖。'
  keep_ui_changes
}

subscription_popup_disabled_in_file() {
  local target="$1"
  grep -q 'PVE_SENSIBLE_NO_SUBSCRIPTION' "$target" ||
    sed -n '/\/nodes\/localhost\/subscription/,+30p' "$target" | grep -Eq 'if[[:space:]]*\([[:space:]]*false[[:space:]]*\)|void[[:space:]]*\('
}

disable_subscription_in_file() {
  local target="$1"
  # From pve-diy: constrain the edit to the subscription API callback, then
  # replace its complete status condition. The marker makes the patch auditable.
  sed -r -i '/\/nodes\/localhost\/subscription/,+30 {
    /^\s+if\s*\(/ {
        :loop
        N
        /\s*\)\s*\{/!b loop
        s/(if\s*\([[:space:]]*res\s*===\s*null\s*(\|\|\s*res\s*===\s*undefined\s*)?(\|\|\s*!res\s*)?(\|\|\s*res\.data\.status\.toLowerCase\(\)\s*!==\s*[\x27\"]active[\x27\"]\s*)?[[:space:]]*\)\s*\{)/if(false){ \/\/ PVE_SENSIBLE_NO_SUBSCRIPTION/
    }
}' "$target"
}

passthrough_status() {
  info 'IOMMU 内核日志：'; dmesg | grep -Ei 'DMAR|IOMMU' | tail -n 20 || true
  info 'PCI 设备：'; lspci -nn
  info 'IOMMU 分组：'
  if [[ -d /sys/kernel/iommu_groups ]]; then
    for g in /sys/kernel/iommu_groups/*; do
      printf 'Group %s: ' "${g##*/}"; lspci -nns "$(basename "$(readlink -f "$g"/* | head -n1)")" 2>/dev/null || true
    done
  else
    printf '未发现 IOMMU 分组。请先在 BIOS/UEFI 和启动参数中启用 IOMMU。\n'
  fi
}

enable_iommu() {
  local grub=/etc/default/grub modules=/etc/modules cpu_arg test_grub test_modules answer
  [[ -f "$grub" ]] || die "未找到 $grub；当前模块仅支持使用 GRUB 的主机。"
  if grep -qi 'AuthenticAMD' /proc/cpuinfo; then cpu_arg='amd_iommu=on iommu=pt'; else cpu_arg='intel_iommu=on iommu=pt'; fi
  printf "将写入 GRUB 参数：%s，并加入 VFIO 基础模块。不会绑定任何 PCI 设备，也不会自动重启。\n" "$cpu_arg"
  read -r -p '确认继续请输入 IOMMU：' answer
  [[ "$answer" == IOMMU ]] || { info '已取消 IOMMU 配置。'; return 0; }
  test_grub=$(mktemp); test_modules=$(mktemp)
  cp -- "$grub" "$test_grub"
  if [[ -f "$modules" ]]; then cp -- "$modules" "$test_modules"; else : >"$test_modules"; fi
  if ! prepare_iommu_files "$test_grub" "$test_modules" "$cpu_arg"; then
    rm -f "$test_grub" "$test_modules"
    die 'GRUB 或 modules 文件结构不兼容；未修改启动配置。'
  fi
  rm -f "$test_grub" "$test_modules"
  begin_transaction iommu
  backup "$grub"; backup "$modules"
  if ! prepare_iommu_files "$grub" "$modules" "$cpu_arg" || ! update-initramfs -u -k all || ! update-grub; then
    restore_source_transaction "$CURRENT_BACKUP_DIR" "$grub" "$modules"
    update-initramfs -u -k all >/dev/null 2>&1 || true
    update-grub >/dev/null 2>&1 || true
    die 'IOMMU 启动配置生成失败，配置文件已恢复并重新生成启动文件。'
  fi
  info 'IOMMU 启动准备已完成。请手动重启后运行菜单 5 检查分组；未自动绑定任何 PCI 设备。'
}

prepare_iommu_files() {
  local grub="$1" modules="$2" args="$3" arg count
  count=$(grep -Ec '^GRUB_CMDLINE_LINUX_DEFAULT="[^"]*"[[:space:]]*$' "$grub" || true)
  [[ "$count" == 1 ]] || return 1
  for arg in $args; do
    if ! grep -Eq "^GRUB_CMDLINE_LINUX_DEFAULT=\"([^\"]*[[:space:]])?${arg}([[:space:]][^\"]*)?\"[[:space:]]*$" "$grub"; then
      sed -i "/^GRUB_CMDLINE_LINUX_DEFAULT=/s/\"[[:space:]]*$/ $arg\"/" "$grub"
    fi
  done
  for module in vfio vfio_iommu_type1 vfio_pci; do
    grep -qxF "$module" "$modules" || printf '%s\n' "$module" >>"$modules"
  done
}

passthrough_wizard() {
  local answer
  passthrough_status
  printf '\n提示：只有确认 BIOS/UEFI 已开启虚拟化与 IOMMU，且已核对设备分组后，才应写入启动参数。\n'
  read -r -p '现在准备 GRUB + VFIO 启动配置吗？[y/N] ' answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] && enable_iommu
}

menu() {
  while true; do
    cat <<'EOF'

PVE 简洁维护工具（PVE 9）
  1) 概要信息定制
  2) 软件源配置（Debian / 企业源 / 无订阅 / Ceph / CT 模板）
  3) 仅关闭登录时的订阅弹窗
  4) 通过 accept_ra=2 为 vmbr0 启用 SLAAC IPv6（不重启网络）
  5) PCI 直通 / IOMMU（检查并按需准备 GRUB + VFIO）
  6) 恢复备份（UI / 软件源 / IPv6 / CT / IOMMU）
  0) 退出
EOF
    read -r -p '请选择：' choice
    case "$choice" in
      1) run_menu_action '概要信息定制' apply_overview ;;
      2) run_menu_action '软件源配置' set_sources ;;
      3) run_menu_action '关闭订阅弹窗' disable_subscription_popup ;;
      4) run_menu_action 'SLAAC IPv6' set_ipv6_slaac ;;
      5) run_menu_action 'PCI 直通 / IOMMU' passthrough_wizard ;;
      6) run_menu_action '恢复备份' restore_backup_menu ;;
      0) exit 0 ;; *) printf '无效选择。\n' ;;
    esac
  done
}

run_menu_action() {
  local label="$1"; shift
  if ! ( "$@" ); then
    printf '\n[%s] 操作未完成，已返回主菜单；请查看上方错误信息。\n' "$label" >&2
  fi
}

if [[ "${PVE_SENSIBLE_LIB_ONLY:-0}" != 1 ]]; then
  need_root
  need_pve9
  menu
fi
