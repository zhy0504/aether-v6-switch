# aether-v6-switch

适用于 **Aether VPS** 的 IPv6 出口切换脚本。  
支持在 **原生 IPv6** 与 **DynamicV6 多地区出口** 之间快速切换，并提供连通性检测、优先级管理、自动巡检、自动切换、IPv6 MTU 修复等能力。

## 功能特性

- 自动识别当前网卡与原生 IPv6 默认路由
- 自动接入 DynamicV6 并获取可用出口线路
- 支持在原生 IPv6 / DynamicV6 多地区线路之间一键切换
- 自动生成管理命令 `qh`
- 支持当前线路检测与全部线路探测
- 连通性检测同时覆盖 ICMPv6、HTTPS 与 MTU 探测，便于判断 PMTU 黑洞问题
- 支持为指定线路自动探测最大稳定路由 `mtu`，也可手动保存并自动应用指定值
- 支持线路优先级排序
- 支持按优先级自动切换到最佳可用线路
- 支持 `systemd timer` / `cron` 定时巡检
- 支持恢复 DynamicV6 变更
- 支持一键卸载

## 安装方法

请使用 `root` 执行：

```bash
wget -O v6.sh https://raw.githubusercontent.com/zhy0504/aether-v6-switch/main/v6.sh && chmod +x v6.sh && sudo bash v6.sh
```

指定网卡安装：

```bash
sudo bash v6.sh --iface eth0
```

非交互安装：

```bash
sudo bash v6.sh --iface eth0 --yes --non-interactive
```

安装完成后会生成快捷管理命令：

```bash
qh
```

## 常用命令

```bash
qh                         # 进入交互菜单
qh list                    # 查看全部线路
qh status                  # 查看当前状态
qh test                    # 检测当前线路 IPv6 连通性（ICMPv6 + HTTPS + MTU）
qh probe                   # 逐条检测全部线路 IPv6 连通性
qh probe jp-2              # 检测指定线路
qh native                  # 切回原生 IPv6
qh 2                       # 按序号切换线路
qh jp                      # 按地区代号切换线路
qh jp-2                    # 按线路代号切换线路
```

## MTU / IPv6 网页访问修复

如果出现“小包 IPv6 能通，但网页 / HTTPS 访问失败或卡住”的情况，通常可能是 IPv6 PMTU 黑洞。可先运行：

```bash
qh test
```

如检测提示 ICMPv6 正常但 HTTPS 异常，可对当前线路自动探测最大稳定 MTU 并写入修复记录：

```bash
qh repair current auto
```

也可以对指定线路自动探测或手动保存修复，后续切换到该线路时会自动带上 `mtu`：

```bash
qh repair jp-2 auto
qh repair native auto
qh repair jp-2 1400      # 手动指定 MTU
qh repair list
```

修复记录保存在：

```text
/var/lib/qh/route_fix.tsv
```

## 优先级与自动切换

```bash
qh priority list           # 查看优先级顺序
qh priority set jp-1 1     # 将指定线路设为最高优先级
qh priority wizard         # 使用字母向导调整优先级
qh auto                    # 按优先级切到最佳可用线路
qh auto on                 # 开启自动守护
qh auto off                # 关闭自动守护
qh auto status             # 查看自动守护状态
```

自动守护会定时执行检测，并按优先级切换到最佳可用 IPv6 线路。

## 还原与卸载

```bash
qh restore                 # 还原 DynamicV6 变更
qh uninstall               # 还原变更并卸载 qh
```

卸载会删除 `qh` 命令、自动守护配置、优先级记录、探测记录和 MTU 修复记录。

## 环境变量

可按需调整探测目标和超时时间：

```bash
QH_IPV6_PROBE_TARGET=2606:4700:4700::1111   # ICMPv6 探测目标
QH_IPV6_HTTPS_URL=https://ipv6.icanhazip.com # HTTPS 探测目标
QH_IPV6_PROBE_COUNT=2                        # ping 次数
QH_IPV6_PROBE_TIMEOUT=3                      # ping 超时秒数
QH_IPV6_HTTP_TIMEOUT=10                      # HTTPS 超时秒数
QH_IPV6_MTU_AUTO_MIN=1280                    # 自动探测 MTU 下限
QH_IPV6_MTU_AUTO_MAX=1500                    # 自动探测 MTU 上限，默认使用网卡 MTU
QH_IPV6_MTU_AUTO_PING_COUNT=20               # 稳定性验证 ping 次数
QH_IPV6_MTU_AUTO_MAX_LOSS_PERCENT=5          # 稳定性验证允许的最大丢包百分比
```

## 注意事项

1. 请务必使用 `root` 运行安装脚本。
2. 本脚本会修改系统 IPv6 默认路由。
3. 建议在有控制台或救援方式的前提下操作，避免误切换后失联。
4. 如果当前系统已经处于 DynamicV6 切换后的路由状态，首次安装前建议先恢复原生线路，再执行安装。
5. 自动切换依赖线路探测结果，建议先手动执行一次 `qh probe` 确认所有线路状态。

## License

本项目基于 **MIT License** 开源。

你可以自由使用、修改、分发和商用，但需保留原始版权声明和许可声明。
