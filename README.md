# sing-box 自搭一键脚本

在 VPS 上一键部署 sing-box，面向中国移动 / 电信 / 联通网络。

## 功能

- **两个基础节点**：VMess-Argo（走 Cloudflare 隧道，移动宽带可用）、VLESS-Reality 直连（电信 / 联通）
- **可选住宅节点**：填入 SOCKS5 住宅代理后自动生成对应节点
- **订阅**：自动生成 base64 订阅链接，客户端刷新即可更新
- **自动维护**：每天 03:00 + 重启后自动检查更新、健康、备份；Argo 域名变了自动重生成链接和订阅
- **Gist 固定订阅**：配好 token 后，订阅内容变了自动推到 GitHub Gist，订阅链接永久不变
- **脚本自更新**：每天 03:30 自动检查仓库，有新版就更新工具（不动配置），手动跑 `sb-update` 也行
- **安全**：BBR、fail2ban、ufw（只放行 SSH 和 VLESS 端口）

## 用法

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/PLA73211/RackNerd-OneKey-Script/main/build-minimal.sh)
```

按提示操作即可。首次运行会生成随机的 UUID、端口和 Reality 密钥。

## 要求

- Ubuntu 22.04 / 24.04 或 Debian 12，root 运行
- 一台有公网 IP 的 VPS

## 说明

- 脚本不含任何个人信息，生成的 UUID、端口、密钥每次运行都随机。
- 订阅、节点信息等运行时数据只存在你自己的 VPS 上，不会上传到这里。
