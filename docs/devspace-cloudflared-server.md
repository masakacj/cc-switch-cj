# DevSpace + Cloudflare Tunnel 一键部署

用于在 **Debian 13 / Ubuntu / Rocky Linux 9** 等 systemd Linux 服务器上部署：

- Node.js 24.x（仅当现有 Node 不满足 DevSpace 要求时安装）
- `@waishnav/devspace@1.0.8`
- Cloudflare `cloudflared`
- 独立 `devspace` 系统用户
- `devspace.service`
- `cloudflared.service`

DevSpace 只监听 `127.0.0.1:7676`，服务器**不需要开放任何公网入站端口**。

> 注意：Cloudflare Tunnel 会创建一个可从互联网访问的 Cloudflare HTTPS 地址。它不是“公网端口直连服务器”，但应用地址本身仍是外部可达的。DevSpace 会要求 Owner password 批准 MCP 客户端。如果公司安全策略要求“应用也绝不能被公网访问”，则不要使用 Cloudflare Tunnel。

## 1. Cloudflare 侧先做一次配置

在 Cloudflare Zero Trust 中创建一个 Named Tunnel，并给它添加 Public Hostname：

```text
https://mcp.example.com
        ↓
http://127.0.0.1:7676
```

然后复制该 Tunnel 的 token。

服务器无需公网 IP，也无需放行 80/443 入站；但必须允许服务器主动访问 Cloudflare 和 GitHub/Node.js 下载源。

## 2. 一键安装

直接在新服务器执行：

```bash
curl -fsSL https://raw.githubusercontent.com/masakacj/cc-switch-cj/main/scripts/install-devspace-cloudflared.sh | sudo bash
```

安装脚本会询问三个值：

1. DevSpace 公网 HTTPS 地址，例如 `https://mcp.example.com`，不要填写 `/mcp`
2. Cloudflare Tunnel token（隐藏输入）
3. DevSpace 可访问的项目目录，默认 `/home/devspace`

安装完成后会显示：

```text
MCP URL
Owner password
DevSpace 本地地址
systemd 服务状态查看命令
```

在 ChatGPT MCP/App 中填写：

```text
https://mcp.example.com/mcp
```

首次连接时使用脚本显示的 Owner password 批准。

## 3. 非交互安装

也支持环境变量：

```bash
sudo env \
  PUBLIC_URL="https://mcp.example.com" \
  CF_TUNNEL_TOKEN="YOUR_TUNNEL_TOKEN" \
  ALLOWED_ROOTS="/home/devspace,/srv/projects" \
  bash install-devspace-cloudflared.sh
```

由于 Tunnel token 属于敏感凭据，日常部署更建议使用交互方式，避免 token 留在 shell history 中。

可选变量：

```text
DEVSPACE_USER=devspace
DEVSPACE_VERSION=1.0.8
DEVSPACE_PORT=7676
NODE_MAJOR=24
```

## 4. 服务管理

```bash
systemctl status devspace cloudflared

journalctl -u devspace -f
journalctl -u cloudflared -f

sudo -u devspace -H /usr/local/bin/devspace doctor
```

配置文件：

```text
/home/devspace/.devspace/config.json
/home/devspace/.devspace/auth.json
/etc/cloudflared/token
/etc/systemd/system/devspace.service
/etc/systemd/system/cloudflared.service
```

其中 `auth.json` 和 `/etc/cloudflared/token` 都应视为密钥文件，不要提交到 Git。

## 5. 权限说明

安装脚本**不会**默认给 `devspace` 用户 `NOPASSWD: ALL` sudo 权限。

默认情况下 DevSpace 可以在配置的 `allowedRoots` 内读写、执行项目命令，但不能直接修改系统级配置。

如果后续需要通过 DevSpace 管理 Docker、Nginx 或 systemd，优先按需要配置受限 sudo 权限。只有明确接受“DevSpace MCP 获得等同 root 的能力”时，才考虑给 `devspace` 完整免密 sudo。

## 6. 网络要求

服务器无需开放公网入站端口。

Cloudflare Tunnel 本身需要主动建立到 Cloudflare 的出站连接。如果公司出口策略阻断 Cloudflare Tunnel，`cloudflared.service` 会启动失败，此时查看：

```bash
journalctl -u cloudflared -n 100 --no-pager
```

公司内网用户如果还需要直接访问本机服务，可以另外由 Nginx 绑定服务器的内网 IP；这与 DevSpace 的 `127.0.0.1:7676` 和 Cloudflare Tunnel 可以并存。
