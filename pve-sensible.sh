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

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
info() { printf '[%s] %s\n' "$APP" "$*"; }
need_root() { [[ $EUID -eq 0 ]] || die '请使用 root 用户运行此脚本。'; }
need_pve9() {
  command -v pveversion >/dev/null || die '当前主机不是 Proxmox VE。'
  pveversion | grep -q 'pve-manager/9\.' || die '本脚本目前仅支持 Proxmox VE 9。'
}
backup() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  [[ -n "$CURRENT_BACKUP_DIR" ]] || die '内部错误：未创建本次操作的备份目录。'
  cp -a -- "$path" "$CURRENT_BACKUP_DIR/$(basename "$path")"
  info "已备份：$CURRENT_BACKUP_DIR/$(basename "$path")"
}
begin_transaction() {
  local label="$1"
  CURRENT_BACKUP_DIR="$STATE_DIR/backups/$(date +%Y%m%d-%H%M%S)-$label"
  mkdir -p "$CURRENT_BACKUP_DIR"
}
confirm() {
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

write_summary_helper() {
  install -d -m 0755 "$LIB_DIR"
  cat >"$SUMMARY_HELPER" <<'EOF'
#!/usr/bin/env bash
set -u
CPU_FREQ=1; CPU_LIMITS=1; CPU_THREAD=0; CPU_GOVERNOR=1; CPU_POWER=0; CPU_TEMP=1; CPU_CORE_TEMP=0; IGPU_TEMP=0; FAN_SPEED=0
UPS_INFO=1; DISK_BASE=1; DISK_POWER=0; DISK_IO=0; OVERVIEW_ALIGN=l
[[ -r /etc/pve-sensible/overview.conf ]] && . /etc/pve-sensible/overview.conf
one_line() { tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'; }
first_match() { grep -m1 -E "$1" 2>/dev/null || true; }

model=$(lscpu | awk -F: '/Model name:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
threads=$(nproc 2>/dev/null || echo '?')
freq=$(lscpu | awk -F: '/CPU MHz:/ {gsub(/^[[:space:]]+/, "", $2); printf "%.0f MHz", $2; exit}')
minmax=$(lscpu | awk -F: '/CPU min MHz:|CPU max MHz:/ {gsub(/^[[:space:]]+/, "", $2); printf "%s ", $2}' | xargs)
gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)
power=$(command -v turbostat >/dev/null 2>&1 && turbostat --quiet --show PkgWatt --interval 0.1 2>/dev/null | tail -n1 | awk '{print $1 " W"}' || true)
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
  temps=$(sensors 2>/dev/null | awk '
    /Package id 0:|Tctl:|CPU Temp:|temp1:/ {gsub(/.*\+/, ""); gsub(/°C.*/, "°C"); if ($0 != "") { print; exit } }
  ')
  [[ -n "$temps" ]] && printf '温度：CPU %s\n' "$temps"
  if [[ "$CPU_CORE_TEMP" == 1 ]]; then
    cores=$(sensors 2>/dev/null | awk '/Core [0-9]+:/ {gsub(/.*\+/, ""); gsub(/°C.*/, "°C"); printf "%s%s", sep, $0; sep=" · "}')
    [[ -n "$cores" ]] && printf '核心温度：%s\n' "$cores"
  fi
fi
if [[ "$IGPU_TEMP" == 1 ]] && command -v sensors >/dev/null 2>&1; then
  gpu=$(sensors 2>/dev/null | awk '/i915|amdgpu|GPU|edge:/ {if ($0 ~ /\+/) {gsub(/.*\+/, ""); gsub(/°C.*/, "°C"); print; exit}}')
  printf '核显温度：%s\n' "${gpu:-未检测到可读的核显温度}"
fi
if [[ "$FAN_SPEED" == 1 ]] && command -v sensors >/dev/null 2>&1; then
  fans=$(sensors 2>/dev/null | awk '/fan[0-9]+:/ {printf "%s%s", sep, $1 " " $2; sep=" · "}')
  printf '风扇转速：%s\n' "${fans:-未检测到风扇转速}"
fi

if [[ "$UPS_INFO" == 1 ]] && command -v apcaccess >/dev/null 2>&1; then
  ups=$(apcaccess status 2>/dev/null || true)
  if [[ -n "$ups" ]]; then
    status=$(printf '%s\n' "$ups" | awk -F: '/^STATUS/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
    charge=$(printf '%s\n' "$ups" | awk -F: '/^BCHARGE/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
    timeleft=$(printf '%s\n' "$ups" | awk -F: '/^TIMELEFT/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
    linev=$(printf '%s\n' "$ups" | awk -F: '/^LINEV/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
    printf 'UPS：%s%s%s%s\n' "${status:-未知}" "${charge:+ · 电池 $charge}" "${timeleft:+ · 剩余 $timeleft}" "${linev:+ · 市电 $linev}"
  fi
elif [[ "$UPS_INFO" == 1 ]]; then
  printf 'UPS：未安装 apcupsd（菜单 8 可安装；apcaccess 由该软件包提供）\n'
fi

if [[ "$DISK_BASE" == 1 ]]; then for dev in /sys/class/nvme/nvme*; do
  [[ -d "$dev" ]] || continue
  name=$(basename "$dev")
  model=$(cat "$dev/model" 2>/dev/null | one_line)
  disk="/dev/$name"
  extra=''
  if command -v smartctl >/dev/null 2>&1; then
    smart=$(smartctl -a "$disk" 2>/dev/null || true)
    temp=$(printf '%s\n' "$smart" | awk -F: '/^Temperature:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
    used=$(printf '%s\n' "$smart" | awk -F: '/^Percentage Used:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
    [[ -n "$temp" ]] && extra+=" · $temp"
    [[ -n "$used" ]] && extra+=" · 已使用 $used"
    if [[ "$DISK_POWER" == 1 ]]; then hours=$(printf '%s\n' "$smart" | awk -F: '/^Power On Hours:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}'); [[ -n "$hours" ]] && extra+=" · 通电 $hours"; fi
  fi
  printf 'NVMe：%s%s%s\n' "$name" "${model:+ · $model}" "$extra"
done; fi
EOF
  chmod 0755 "$SUMMARY_HELPER"
}

overview_defaults() {
  CPU_FREQ=1; CPU_LIMITS=1; CPU_THREAD=0; CPU_GOVERNOR=1; CPU_POWER=0; CPU_TEMP=1; CPU_CORE_TEMP=0; IGPU_TEMP=0; FAN_SPEED=0
  UPS_INFO=1; DISK_BASE=1; DISK_POWER=0; DISK_IO=0; OVERVIEW_ALIGN=l
}
overview_load() {
  overview_defaults
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
      overview_save
      if [[ "$UPS_INFO" == 1 ]] && ! command -v apcaccess >/dev/null 2>&1; then
        install_ups_support
      fi
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
  systemctl stop "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" 2>/dev/null || true
  systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active=3m "$ROLLBACK_HELPER" "$CURRENT_BACKUP_DIR"
  info "已启用 3 分钟自动回退保护（$purpose）。"
}

keep_ui_changes() {
  local answer=''
  info '请在另一个浏览器标签页打开 PVE，并强制刷新页面。'
  info '确认概要页或登录页正常后，请在 180 秒内输入 KEEP 保留本次修改。'
  read -r -t 180 -p '确认：' answer || true
  if [[ "$answer" == KEEP ]]; then
    systemctl stop "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" 2>/dev/null || true
    info '已保留修改，自动回退已取消。'
  else
    info '未收到 KEEP 确认；原始 UI 文件将自动恢复。'
  fi
}

restore_latest_ui() {
  local latest
  latest=$(find "$STATE_DIR/backups" -mindepth 2 -maxdepth 2 -type f -name Nodes.pm -printf '%h\n' 2>/dev/null | sort | tail -n1 || true)
  [[ -n "$latest" ]] || die '未找到可用于恢复的概要 UI 备份。'
  write_rollback_helper
  "$ROLLBACK_HELPER" "$latest"
  info "已从以下备份恢复 UI 文件：$latest"
}

preflight_overview_compatibility() {
  local node_test js_test
  node_test=$(mktemp) || die '无法创建概要信息兼容性测试文件。'
  js_test=$(mktemp) || { rm -f "$node_test"; die '无法创建概要信息兼容性测试文件。'; }
  cp -- "$NODES_PM" "$node_test"
  cp -- "$MANAGER_JS" "$js_test"
  if ! grep -q 'PVE_SENSIBLE_OVERVIEW' "$node_test"; then
    if ! perl -0777 -i -pe 's{(\$res->\{pveversion\}\s*=\s*[^;]+;)}{$1\n\t# PVE_SENSIBLE_OVERVIEW\n\t$res->{pve_sensible_summary} = qx(/usr/local/lib/pve-sensible/summary.sh);\n} or die "no match\n"' "$node_test" 2>/dev/null || ! grep -q 'PVE_SENSIBLE_OVERVIEW' "$node_test"; then
      rm -f "$node_test" "$js_test"
      die '当前 PVE 的 Nodes.pm 与脚本不兼容；未修改任何文件。请提交 pveversion 附近的代码后再适配。'
    fi
  fi
  if ! grep -q 'PVE_SENSIBLE_OVERVIEW' "$js_test"; then
    if ! perl -0777 -i -pe 's{(itemId:\s*[\x27\"]pveversion[\x27\"][\s\S]{0,1000}?\n\s*\},)}{$1\n\t\t// PVE_SENSIBLE_OVERVIEW\n\t\t{\n\t\t\titemId: \x27pve-sensible-summary\x27, colspan: 2, printBar: false,\n\t\t\ttitle: gettext(\x27硬件状态\x27), textField: \x27pve_sensible_summary\x27,\n\t\t\trenderer: function(value) { return Ext.htmlEncode(value || \x27\x27).replace(/\\n/g, \x27<br>\x27); },\n\t\t},)}s or die "no match\n"' "$js_test" 2>/dev/null || ! grep -q 'PVE_SENSIBLE_OVERVIEW' "$js_test"; then
      rm -f "$node_test" "$js_test"
      die '当前 PVE 的 pvemanagerlib.js 与脚本不兼容；未修改任何文件。请提交 pveversion 概要项附近的代码后再适配。'
    fi
  fi
  rm -f "$node_test" "$js_test"
  info '概要信息兼容性预检通过：实际文件可完成后端与前端插入。'
}

apply_overview() {
  [[ -f "$NODES_PM" && -f "$MANAGER_JS" ]] || die '未找到 PVE 前端文件。'
  configure_overview || return 0
  preflight_overview_compatibility
  begin_transaction overview
  backup "$NODES_PM"; backup "$MANAGER_JS"
  schedule_ui_rollback 'overview installation'
  write_summary_helper

  if ! grep -q 'PVE_SENSIBLE_OVERVIEW' "$NODES_PM"; then
    perl -0777 -i -pe 's{(\$res->\{pveversion\}\s*=\s*[^;]+;)}{$1\n\t# PVE_SENSIBLE_OVERVIEW\n\t$res->{pve_sensible_summary} = qx(/usr/local/lib/pve-sensible/summary.sh);\n} or die "PVE_SENSIBLE: Nodes.pm insertion point not found\n"' "$NODES_PM"
  fi
  if ! grep -q 'PVE_SENSIBLE_OVERVIEW' "$MANAGER_JS"; then
    perl -0777 -i -pe 's{(itemId:\s*[\x27\"]pveversion[\x27\"][\s\S]{0,1000}?\n\s*\},)}{$1\n\t\t// PVE_SENSIBLE_OVERVIEW\n\t\t{\n\t\t\titemId: \x27pve-sensible-summary\x27, colspan: 2, printBar: false,\n\t\t\ttitle: gettext(\x27硬件状态\x27), textField: \x27pve_sensible_summary\x27,\n\t\t\trenderer: function(value) { return Ext.htmlEncode(value || \x27\x27).replace(/\\n/g, \x27<br>\x27); },\n\t\t},)}s or die "PVE_SENSIBLE: pvemanagerlib.js insertion point not found\n"' "$MANAGER_JS"
  fi
  if ! perl -c "$NODES_PM" >/dev/null; then "$ROLLBACK_HELPER" "$CURRENT_BACKUP_DIR"; die 'Perl 校验失败，原始文件已恢复。'; fi
  systemctl restart pveproxy
  systemctl is-active --quiet pveproxy || { "$ROLLBACK_HELPER" "$CURRENT_BACKUP_DIR"; die 'pveproxy 未能启动，原始文件已恢复。'; }
  command -v curl >/dev/null && curl -ksf https://127.0.0.1:8006/api2/json/version >/dev/null || true
  keep_ui_changes
}

set_ipv6_slaac() {
  local file=/etc/network/interfaces
  [[ -f "$file" ]] || die "$file 不存在。"
  grep -qE '^\s*iface\s+vmbr0\s+inet6\s+' "$file" && die 'vmbr0 已有 inet6 配置，不能叠加本 SLAAC 方案。'
  begin_transaction ipv6
  backup "$file"
  if ! grep -q 'PVE_SENSIBLE_SLAAC' "$file"; then
    sed -i '/^source \/etc\/network\/interfaces\.d\/\*/i\    post-up sysctl -qw net.ipv6.conf.vmbr0.accept_ra=2 # PVE_SENSIBLE_SLAAC' "$file"
  fi
  grep -q 'PVE_SENSIBLE_SLAAC' "$file" || die '未找到安全的 vmbr0 写入位置，未完成持久化修改。'
  sysctl -qw net.ipv6.conf.vmbr0.accept_ra=2
  info '已加入 SLAAC 配置。为避免远程断连，未重启网络；请在本机控制台执行：systemctl restart networking'
  ip -6 addr show dev vmbr0 scope global || true
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
    1) MIRROR_NAME='清华 TUNA'; DEBIAN_URI=https://mirrors.tuna.tsinghua.edu.cn/debian; SECURITY_URI=https://security.debian.org/debian-security; PVE_URI=https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve; CEPH_URI=https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/ceph-squid; CT_URI=https://mirrors.tuna.tsinghua.edu.cn/proxmox ;;
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
  if ! perl -0777 -i -pe 's{https?://(?:download\.proxmox\.com|mirrors\.(?:tuna\.tsinghua\.edu\.cn|ustc\.edu\.cn))/proxmox(?=/|[\x27\"])}{'"$CT_URI"'}g' "$apl"; then
    restore_source_transaction "$CURRENT_BACKUP_DIR" "$apl"
    die 'CT 模板源定位失败；原文件已恢复。'
  fi
  grep -qF "$CT_URI" "$apl" || { restore_source_transaction "$CURRENT_BACKUP_DIR" "$apl"; die 'CT 模板源定位失败；原文件已恢复。'; }
  info "CT 模板源已改为 $MIRROR_NAME。执行 pveam update 后生效；PVE 更新后可通过备份记录重新应用。"
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
  if grep -q 'PVE_SENSIBLE_NO_SUBSCRIPTION' "$TOOLKIT_JS"; then info '订阅弹窗补丁已存在。'; return; fi
  test_file=$(mktemp) || die '无法创建订阅弹窗兼容性测试文件。'
  cp -- "$TOOLKIT_JS" "$test_file"
  if ! perl -0777 -i -pe 's~(Ext\.Msg\.show)(\(\{\s*title:\s*gettext\([\x27\"]No valid subscription)~Ext.emptyFn /* PVE_SENSIBLE_NO_SUBSCRIPTION */$2~s' "$test_file" 2>/dev/null || ! grep -q 'PVE_SENSIBLE_NO_SUBSCRIPTION' "$test_file"; then
    rm -f "$test_file"
    die '当前 PVE 前端的订阅弹窗定位不兼容；未修改任何文件。'
  fi
  rm -f "$test_file"
  begin_transaction subscription-popup
  backup "$TOOLKIT_JS"
  schedule_ui_rollback 'subscription-popup patch'
  if ! perl -0777 -i -pe 's~(Ext\.Msg\.show)(\(\{\s*title:\s*gettext\([\x27\"]No valid subscription)~Ext.emptyFn /* PVE_SENSIBLE_NO_SUBSCRIPTION */$2~s' "$TOOLKIT_JS"; then
    "$ROLLBACK_HELPER" "$CURRENT_BACKUP_DIR"
    die '订阅弹窗补丁写入失败，原始文件已恢复。'
  fi
  systemctl restart pveproxy
  systemctl is-active --quiet pveproxy || { "$ROLLBACK_HELPER" "$CURRENT_BACKUP_DIR"; die 'pveproxy 未能启动，原始文件已恢复。'; }
  info '登录订阅弹窗补丁已应用。PVE 软件包升级后可能会被覆盖。'
  keep_ui_changes
}

install_ups_support() {
  if command -v apcaccess >/dev/null 2>&1; then
    info '已检测到 apcaccess，未进行软件包修改。'
    apcaccess status 2>/dev/null | grep -E '^(STATUS|BCHARGE|TIMELEFT|LINEV)' || true
    return 0
  fi
  info '此操作安装 Debian 的 apcupsd 软件包；不会安装 NUT，也不会改动其他 UPS 服务。'
  info '该软件包提供 apcupsd 服务和概要读取所需的 apcaccess 命令。'
  confirm '现在安装 apcupsd 吗？' || return 0
  apt update
  apt install -y apcupsd
  if command -v apcaccess >/dev/null 2>&1; then
    info 'apcupsd 已安装。请在依赖其断电保护前，确认配置、USB/串口设备和服务状态。'
    systemctl --no-pager --full status apcupsd || true
  else
    die 'apcupsd 安装完成，但未找到 apcaccess 命令。'
  fi
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
  local grub=/etc/default/grub cpu_arg
  [[ -f "$grub" ]] || die "未找到 $grub；当前模块仅支持使用 GRUB 的主机。"
  if grep -qi 'AuthenticAMD' /proc/cpuinfo; then cpu_arg='amd_iommu=on iommu=pt'; else cpu_arg='intel_iommu=on iommu=pt'; fi
  confirm "添加 '$cpu_arg' 与 VFIO 模块吗？完成后需要手动重启。" || return 0
  begin_transaction iommu
  backup "$grub"; backup /etc/modules
  grep -q "$cpu_arg" "$grub" || sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $cpu_arg\"/" "$grub"
  for module in vfio vfio_iommu_type1 vfio_pci; do grep -qx "$module" /etc/modules || echo "$module" >>/etc/modules; done
  update-initramfs -u -k all
  update-grub
  info 'IOMMU 启动准备已完成。请手动重启后运行菜单 5 检查分组；未自动绑定任何 PCI 设备。'
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
  6) 恢复最近一次备份的 PVE UI 文件
  0) 退出
EOF
    read -r -p '请选择：' choice
    case "$choice" in
      1) apply_overview ;; 2) set_sources ;; 3) disable_subscription_popup ;;
      4) set_ipv6_slaac ;; 5) passthrough_wizard ;; 6) restore_latest_ui ;;
      0) exit 0 ;; *) printf '无效选择。\n' ;;
    esac
  done
}

need_root; need_pve9; menu

