# PVE Sensible

一个面向 Proxmox VE 9 的小型、菜单式维护脚本。它只包含经常需要、且可以明确回退的项目：简洁概览、软件源、无订阅登录弹窗、`vmbr0` SLAAC 与 IOMMU 直通准备。

不包含 NUT、UPS 服务迁移、内核删除、网卡改名、CPU 调频、自动 PCI 设备绑定或自动重启。

## 概览排版

“硬件状态”只使用一个跨两列的字段，且固定为左对齐的短行：CPU、CPU 温度、UPS（仅检测既有的 `apcaccess`）、每块 NVMe。不会展示每线程频率或逐核心温度，避免长文字打散 PVE 原生两列布局。

这会修改 PVE 的 `Nodes.pm` 与 `pvemanagerlib.js`。脚本会先备份到 `/var/lib/pve-sensible/backups/<时间戳>/`，并在重启 `pveproxy` 前执行 `perl -c` 校验。

更重要的是，概览与订阅弹窗改动会先安排 **3 分钟自动回退**。脚本重启 `pveproxy` 并检查服务后，会要求你在 SSH 会话里输入 `KEEP`；只有确认浏览器页面正常，才会取消自动回退。没有输入 `KEEP`、断开 SSH，或页面无法打开时，原始 UI 文件会自行恢复。菜单第 7 项也可手动恢复最近一次 UI 备份。

PVE 包升级可能覆盖修改；之后重新执行“安装概览”即可。

### UPS 依赖

UPS 行使用 `apcaccess status` 读取信息。`apcaccess` 不是独立插件，而是 Debian `apcupsd` 软件包附带的命令。

若尚未安装，菜单第 8 项会在明确确认后执行 `apt install apcupsd`；它不会安装或替换为 NUT，也不会改写一个已经存在的 `apcupsd` 配置。安装完成只代表概览具备读取能力，仍必须自行确认 `apcupsd` 服务、USB/串口设备和断电关机策略实际工作。

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

## 直通

“直通准备”只写入 IOMMU 启动参数和 VFIO 模块，必须手动重启。它不会猜测、更不会绑定 PCI 设备；绑定错误的网卡、系统盘控制器或核显会让宿主机失联或无法启动。

## 使用

先复制脚本到 PVE 9 主机，检查后执行：

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

