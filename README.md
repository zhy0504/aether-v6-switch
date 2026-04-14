# aether-v6-switch

适用于 **Aether VPS** 的 IPv6 出口切换脚本。  
支持在 **原生 IPv6** 与 **DynamicV6 多地区出口** 之间快速切换，并提供 **连通性检测、优先级管理、自动巡检、自动切换** 等能力。

## 功能特性

- 自动识别当前网卡与原生 IPv6 默认路由
- 自动接入 DynamicV6 并获取可用出口线路
- 支持在原生 IPv6 / DynamicV6 多地区线路之间一键切换
- 自动生成管理命令 `qh`
- 支持当前线路检测与全部线路探测
- 支持线路优先级排序
- 支持按优先级自动切换到最佳可用线路
- 支持 `systemd timer` / `cron` 定时巡检
- 支持恢复 DynamicV6 变更
- 支持一键卸载

## 安装方法

一键安装

```
wget -O install.sh https://raw.githubusercontent.com/endview/aether-v6-switch/main/v6.sh && chmod +x install.sh && sudo bash install.sh
```


## 注意事项

1. 请务必使用 `root` 运行安装脚本。
2. 本脚本会修改系统 IPv6 默认路由。
3. 建议在有控制台或救援方式的前提下操作，避免误切换后失联。
4. 如果当前系统已经处于 DynamicV6 切换后的路由状态，首次安装前建议先恢复原生线路，再执行安装。
5. 自动切换依赖线路探测结果，建议先手动执行一次 `qh probe` 确认所有线路状态。

---

## FAQ
>  Q：干嘛的

- A：不知道
>  Q：怎么写得这么臭

- A：不知道，我不会写，ai干的

  
## License

本项目基于 **MIT License** 开源。

你可以自由使用、修改、分发和商用，但需保留原始版权声明和许可声明。
