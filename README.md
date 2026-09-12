# PVE Sensible

一个面向 Proxmox VE 9 的小型、菜单式维护脚本。它只包含经常需要、且可以明确回退的项目：简洁概览、软件源、无订阅登录弹窗、`vmbr0` SLAAC 与 IOMMU 直通准备。

不包含 NUT、UPS 服务迁移、内核删除、网卡改名、CPU 调频、自动 PCI 设备绑定或自动重启。

## 概览排版

“硬件状态”使用一个跨两列、左对齐的字段，避免长文本在 PVE 原生两列中错位。进入菜单 1 后可逐项选择 CPU 实时/最小最大频率、工作模式、功耗、CPU/核心温度、UPS、NVMe 基础/通电/IO 信息，也可使用“高大全、精简、极简”预设。

默认是精简方案：实时/最小最大频率、工作模式、CPU 温度、UPS 和 NVMe 基础信息。核心温度和逐项 IO 信息默认关闭，因为核心数多或磁盘多时会明显拉长概要页。

预设的具体内容：`o` 高大全为所有项目；`p` 精简为实时/最小最大频率、工作模式、CPU 温度、UPS、NVMe 基础；`q` 极简为实时频率、CPU 温度、UPS、NVMe 基础。选择后脚本会先显示本次概要预览；按 Enter 才会继续实际应用，输入 `r` 可以返回调整。

这会修改 PVE 的 `Nodes.pm` 与 `pvemanagerlib.js`。脚本会先备份到 `/var/lib/pve-sensible/backups/<时间戳>/`，并在重启 `pveproxy` 前执行 `perl -c` 校验。

更重要的是，概览与订阅弹窗改动会先安排 **3 分钟自动回退**。脚本重启 `pveproxy` 并检查服务后，会要求你在 SSH 会话里输入 `KEEP`；只有确认浏览器页面正常，才会取消自动回退。没有输入 `KEEP`、断开 SSH，或页面无法打开时，原始 UI 文件会自行恢复。菜单第 7 项也可手动恢复最近一次 UI 备份。

PVE 包升级可能覆盖修改；之后重新执行“安装概览”即可。

### UPS 依赖

UPS 行使用 `apcaccess status` 读取信息。`apcaccess` 不是独立插件，而是 Debian `apcupsd` 软件包附带的命令。

若你在概要定制向导中启用 UPS 信息、但尚未安装，脚本会在明确确认后执行 `apt install apcupsd`；它不会安装或替换为 NUT，也不会改写一个已经存在的 `apcupsd` 配置。安装完成只代表概览具备读取能力，仍必须自行确认 `apcupsd` 服务、USB/串口设备和断电关机策略实际工作。

## IPv6

IPv6 采用已验证的 SLAAC 方案：在 `/etc/network/interfaces` 的 `vmbr0` 段加入：

```text
post-up sysctl -qw net.ipv6.conf.vmbr0.accept_ra=2
```

脚本不会重启网络，避免远程连接中断。请在本机控制台自行执行 `systemctl restart networking`，或在下一次重启后验证：

```bash
ip -6 addr show dev vmbr0 scope global
```

如果已有 `iface vmbr0 inet6 ...` 配置，脚本会拒绝叠加，必须先人工确认现状。

## 软件源

菜单第 2 项提供三个 **PVE 9 / Debian 13 (trixie)** 预设：清华 TUNA、中科大 USTC、官方 Debian + Proxmox。所有预设均启用 `pve-no-subscription`，并注释现有企业源；不会伪造订阅，也不会处理 Ceph 或 CT 模板源。切换前会备份源文件并要求二次确认，完成后才运行 `apt update`。

## 直通

“直通准备”只写入 IOMMU 启动参数和 VFIO 模块，必须手动重启。它不会猜测、更不会绑定 PCI 设备；绑定错误的网卡、系统盘控制器或核显会让宿主机失联或无法启动。

## 使用

在 PVE 9 的 Shell 中执行以下一行即可下载并启动：

```bash
wget -qO /root/pve-sensible.sh https://raw.githubusercontent.com/FANGSEANG/pve-sensible/main/pve-sensible.sh && chmod 700 /root/pve-sensible.sh && /root/pve-sensible.sh
```

它会把脚本保留在 `/root/pve-sensible.sh`，不会使用不便审查的 `curl | bash` 方式。首次使用建议先选择菜单 `1`，确认浏览器页面正常后在 SSH 会话输入 `KEEP`。

后续再次打开菜单，直接执行：

```bash
bash /root/pve-sensible.sh
```

如需更新为 GitHub 上的最新版，再重新执行上面的 `wget` 一行命令即可。

也可以先复制脚本到 PVE 9 主机，检查后执行：

```bash
chmod +x pve-sensible.sh
sudo ./pve-sensible.sh
```

## 设计参考

- `pve_source` 的 PVE 概览信息定制思路；本项目未直接执行其全功能脚本。
- ZhiChao 的 PVE 9 文档中经实测的 `vmbr0` `accept_ra=2` SLAAC 思路。

项目将这两部分拆开，并增加了 UI 改动的自动回退机制。

## 免责声明

这不是 Proxmox 官方工具。任何改动 PVE 前端或软件源的操作都应先有可用备份和本机控制台；在生产集群中请先于单节点测试。

