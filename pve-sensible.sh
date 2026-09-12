#!/usr/bin/env bash
# pve-sensible - a small, reversible helper for Proxmox VE 9
# License: MIT
set -Eeuo pipefail

readonly APP="pve-sensible"
readonly STATE_DIR="/var/lib/${APP}"
readonly LIB_DIR="/usr/local/lib/${APP}"
readonly SUMMARY_HELPER="${LIB_DIR}/summary.sh"
readonly NODES_PM="/usr/share/perl5/PVE/API2/Nodes.pm"
readonly MANAGER_JS="/usr/share/pve-manager/js/pvemanagerlib.js"
readonly TOOLKIT_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
readonly ROLLBACK_HELPER="${LIB_DIR}/rollback-ui.sh"
readonly ROLLBACK_UNIT="pve-sensible-ui-rollback"
CURRENT_BACKUP_DIR=''

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
info() { printf '[%s] %s\n' "$APP" "$*"; }
need_root() { [[ $EUID -eq 0 ]] || die 'Run this script as root.'; }
need_pve9() {
  command -v pveversion >/dev/null || die 'This host does not look like Proxmox VE.'
  pveversion | grep -q 'pve-manager/9\.' || die 'Only Proxmox VE 9 is supported.'
}
backup() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  [[ -n "$CURRENT_BACKUP_DIR" ]] || die 'Internal error: no transaction backup directory.'
  cp -a -- "$path" "$CURRENT_BACKUP_DIR/$(basename "$path")"
  info "Backup: $CURRENT_BACKUP_DIR/$(basename "$path")"
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
one_line() { tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'; }
first_match() { grep -m1 -E "$1" 2>/dev/null || true; }

model=$(lscpu | awk -F: '/Model name:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
threads=$(nproc 2>/dev/null || echo '?')
freq=$(lscpu | awk -F: '/CPU MHz:/ {gsub(/^[[:space:]]+/, "", $2); printf "%.0f MHz", $2; exit}')
gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)
printf 'CPU：%s · %s 线程%s%s\n' "${model:-未知型号}" "$threads" "${freq:+ · $freq}" "${gov:+ · $gov}"

if command -v sensors >/dev/null 2>&1; then
  temps=$(sensors 2>/dev/null | awk '
    /Package id 0:|Tctl:|CPU Temp:|temp1:/ {gsub(/.*\+/, ""); gsub(/°C.*/, "°C"); if ($0 != "") { print; exit } }
  ')
  [[ -n "$temps" ]] && printf '温度：CPU %s\n' "$temps"
fi

if command -v apcaccess >/dev/null 2>&1; then
  ups=$(apcaccess status 2>/dev/null || true)
  if [[ -n "$ups" ]]; then
    status=$(printf '%s\n' "$ups" | awk -F: '/^STATUS/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
    charge=$(printf '%s\n' "$ups" | awk -F: '/^BCHARGE/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
    timeleft=$(printf '%s\n' "$ups" | awk -F: '/^TIMELEFT/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
    linev=$(printf '%s\n' "$ups" | awk -F: '/^LINEV/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
    printf 'UPS：%s%s%s%s\n' "${status:-未知}" "${charge:+ · 电池 $charge}" "${timeleft:+ · 剩余 $timeleft}" "${linev:+ · 市电 $linev}"
  fi
else
  printf 'UPS：未安装 apcupsd（菜单 8 可安装；apcaccess 由该软件包提供）\n'
fi

for dev in /sys/class/nvme/nvme*; do
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
  fi
  printf 'NVMe：%s%s%s\n' "$name" "${model:+ · $model}" "$extra"
done
EOF
  chmod 0755 "$SUMMARY_HELPER"
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
  info "Safety rollback armed for 3 minutes ($purpose)."
}

keep_ui_changes() {
  local answer=''
  info 'Open the PVE page in another browser tab and force-refresh it now.'
  info 'Type KEEP within 180 seconds only after the page opens and the overview/login behaves normally.'
  read -r -t 180 -p 'Confirmation: ' answer || true
  if [[ "$answer" == KEEP ]]; then
    systemctl stop "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" 2>/dev/null || true
    info 'Changes kept; the automatic rollback was cancelled.'
  else
    info 'No KEEP confirmation received. The original UI files will be restored automatically.'
  fi
}

restore_latest_ui() {
  local latest
  latest=$(find "$STATE_DIR/backups" -mindepth 2 -maxdepth 2 -type f -name Nodes.pm -printf '%h\n' 2>/dev/null | sort | tail -n1 || true)
  [[ -n "$latest" ]] || die 'No overview backup was found.'
  write_rollback_helper
  "$ROLLBACK_HELPER" "$latest"
  info "Restored UI files from: $latest"
}

apply_overview() {
  [[ -f "$NODES_PM" && -f "$MANAGER_JS" ]] || die 'PVE UI files were not found.'
  begin_transaction overview
  backup "$NODES_PM"; backup "$MANAGER_JS"
  schedule_ui_rollback 'overview installation'
  write_summary_helper

  if ! grep -q 'PVE_SENSIBLE_OVERVIEW' "$NODES_PM"; then
    perl -0777 -i -pe 's{(\$res->\{pveversion\}\s*=\s*PVE::pvecfg::package\(\);)}{$1\n\t# PVE_SENSIBLE_OVERVIEW\n\t$res->{pve_sensible_summary} = qx(/usr/local/lib/pve-sensible/summary.sh);\n} or die "PVE_SENSIBLE: Nodes.pm insertion point not found\n"' "$NODES_PM"
  fi
  if ! grep -q 'PVE_SENSIBLE_OVERVIEW' "$MANAGER_JS"; then
    perl -0777 -i -pe 's{(itemId:\s*[\x27\"]pveversion[\x27\"][\s\S]{0,1000}?\n\s*\},)}{$1\n\t\t// PVE_SENSIBLE_OVERVIEW\n\t\t{\n\t\t\titemId: \x27pve-sensible-summary\x27, colspan: 2, printBar: false,\n\t\t\ttitle: gettext(\x27硬件状态\x27), textField: \x27pve_sensible_summary\x27,\n\t\t\trenderer: function(value) { return Ext.htmlEncode(value || \x27\x27).replace(/\\n/g, \x27<br>\x27); },\n\t\t},)}s or die "PVE_SENSIBLE: pvemanagerlib.js insertion point not found\n"' "$MANAGER_JS"
  fi
  if ! perl -c "$NODES_PM" >/dev/null; then "$ROLLBACK_HELPER" "$CURRENT_BACKUP_DIR"; die 'Perl validation failed; original files were restored.'; fi
  systemctl restart pveproxy
  systemctl is-active --quiet pveproxy || { "$ROLLBACK_HELPER" "$CURRENT_BACKUP_DIR"; die 'pveproxy did not start; original files were restored.'; }
  command -v curl >/dev/null && curl -ksf https://127.0.0.1:8006/api2/json/version >/dev/null || true
  keep_ui_changes
}

set_ipv6_slaac() {
  local file=/etc/network/interfaces
  [[ -f "$file" ]] || die "$file does not exist."
  grep -qE '^\s*iface\s+vmbr0\s+inet6\s+' "$file" && die 'vmbr0 already has an inet6 stanza; do not layer this SLAAC method on top of it.'
  begin_transaction ipv6
  backup "$file"
  if ! grep -q 'PVE_SENSIBLE_SLAAC' "$file"; then
    sed -i '/^source \/etc\/network\/interfaces\.d\/\*/i\    post-up sysctl -qw net.ipv6.conf.vmbr0.accept_ra=2 # PVE_SENSIBLE_SLAAC' "$file"
  fi
  grep -q 'PVE_SENSIBLE_SLAAC' "$file" || die 'Could not find a safe vmbr0 insertion point; interfaces was not changed persistently.'
  sysctl -qw net.ipv6.conf.vmbr0.accept_ra=2
  info 'SLAAC configuration added. Network was not restarted; apply it in a local console with: systemctl restart networking'
  ip -6 addr show dev vmbr0 scope global || true
}

set_sources_tuna() {
  local codename debian=/etc/apt/sources.list.d/debian.sources pve=/etc/apt/sources.list.d/pve-no-subscription.sources enterprise=/etc/apt/sources.list.d/pve-enterprise.sources
  codename=$(. /etc/os-release; printf '%s' "$VERSION_CODENAME")
  [[ "$codename" == trixie ]] || die "Expected Debian trixie for PVE 9, found: $codename"
  confirm 'Replace Debian and PVE repository definitions with Tsinghua mirror settings?' || return 0
  begin_transaction sources
  backup "$debian"; backup "$pve"; backup "$enterprise"
  cat >"$debian" <<EOF
Types: deb
URIs: https://mirrors.tuna.tsinghua.edu.cn/debian
Suites: trixie trixie-updates trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  cat >"$pve" <<EOF
Types: deb
URIs: https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  [[ -f "$enterprise" ]] && sed -i 's/^\([^#]\)/# \1/' "$enterprise"
  apt update
}

disable_subscription_popup() {
  [[ -f "$TOOLKIT_JS" ]] || die 'Proxmox widget toolkit file was not found.'
  begin_transaction subscription-popup
  backup "$TOOLKIT_JS"
  if grep -q 'PVE_SENSIBLE_NO_SUBSCRIPTION' "$TOOLKIT_JS"; then info 'Subscription popup patch is already present.'; return; fi
  schedule_ui_rollback 'subscription-popup patch'
  perl -0777 -i -pe 's{(Ext\.Msg\.show\(\{\s*title:\s*gettext\([\x27\"]No valid subscription)}{void({ // PVE_SENSIBLE_NO_SUBSCRIPTION\n$1}s or die "PVE_SENSIBLE: subscription popup insertion point not found\n"' "$TOOLKIT_JS"
  systemctl restart pveproxy
  systemctl is-active --quiet pveproxy || { "$ROLLBACK_HELPER" "$CURRENT_BACKUP_DIR"; die 'pveproxy did not start; original files were restored.'; }
  info 'Login popup patch applied. This UI-only patch may be overwritten by package upgrades.'
  keep_ui_changes
}

install_ups_support() {
  if command -v apcaccess >/dev/null 2>&1; then
    info 'apcaccess is already available; no package change was made.'
    apcaccess status 2>/dev/null | grep -E '^(STATUS|BCHARGE|TIMELEFT|LINEV)' || true
    return 0
  fi
  info 'This installs the Debian apcupsd package. It does not install NUT or alter another UPS service.'
  info 'The package provides both the apcupsd daemon and the apcaccess command used by the overview.'
  confirm 'Install apcupsd now?' || return 0
  apt update
  apt install -y apcupsd
  if command -v apcaccess >/dev/null 2>&1; then
    info 'apcupsd installed. Verify its own configuration and USB/serial device before relying on shutdown protection.'
    systemctl --no-pager --full status apcupsd || true
  else
    die 'The apcupsd installation finished but apcaccess was not found.'
  fi
}

passthrough_status() {
  info 'IOMMU kernel messages:'; dmesg | grep -Ei 'DMAR|IOMMU' | tail -n 20 || true
  info 'PCI devices:'; lspci -nn
  info 'IOMMU groups:'
  if [[ -d /sys/kernel/iommu_groups ]]; then
    for g in /sys/kernel/iommu_groups/*; do
      printf 'Group %s: ' "${g##*/}"; lspci -nns "$(basename "$(readlink -f "$g"/* | head -n1)")" 2>/dev/null || true
    done
  else
    printf 'No IOMMU groups exposed. Enable it in firmware and boot parameters first.\n'
  fi
}

enable_iommu() {
  local grub=/etc/default/grub cpu_arg
  [[ -f "$grub" ]] || die "$grub not found. This module currently supports GRUB hosts only."
  if grep -qi 'AuthenticAMD' /proc/cpuinfo; then cpu_arg='amd_iommu=on iommu=pt'; else cpu_arg='intel_iommu=on iommu=pt'; fi
  confirm "Add '$cpu_arg' and VFIO modules? A reboot will be required." || return 0
  backup "$grub"; backup /etc/modules
  grep -q "$cpu_arg" "$grub" || sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $cpu_arg\"/" "$grub"
  for module in vfio vfio_iommu_type1 vfio_pci; do grep -qx "$module" /etc/modules || echo "$module" >>/etc/modules; done
  update-initramfs -u -k all
  update-grub
  info 'IOMMU boot preparation complete. Reboot manually, then run option 5 to verify groups. No PCI device was bound.'
}

menu() {
  while true; do
    cat <<'EOF'

PVE Sensible (PVE 9)
  1) Install concise, left-aligned hardware overview
  2) Configure Tsinghua Debian/PVE no-subscription repositories
  3) Disable only the login subscription popup
  4) Enable vmbr0 SLAAC via accept_ra=2 (does not restart networking)
  5) Check IOMMU / PCI passthrough readiness
  6) Prepare GRUB + VFIO for IOMMU passthrough (reboot required)
  7) Restore the latest backed-up PVE UI files
  8) Install apcupsd for UPS overview (does not use NUT)
  0) Exit
EOF
    read -r -p 'Choose: ' choice
    case "$choice" in
      1) apply_overview ;; 2) set_sources_tuna ;; 3) disable_subscription_popup ;;
      4) set_ipv6_slaac ;; 5) passthrough_status ;; 6) enable_iommu ;; 7) restore_latest_ui ;;
      8) install_ups_support ;;
      0) exit 0 ;; *) printf 'Invalid choice.\n' ;;
    esac
  done
}

need_root; need_pve9; menu

