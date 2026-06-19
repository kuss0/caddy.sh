# caddy.sh

一键安装带 Cloudflare DNS 插件的 Caddy，并用简单命令管理 HTTPS 反向代理站点。

脚本使用 Cloudflare DNS-01 申请证书，所以证书签发本身不依赖 80 端口的 HTTP-01 验证。但 Caddy 作为对外 Web 服务时仍需要监听 80/443。

## 一键安装 / 维护菜单

直接执行：

```bash
bash <(wget -O- https://github.com/kuss0/caddy.sh/raw/main/install.sh)
```

或使用 curl：

```bash
bash <(curl -fL https://github.com/kuss0/caddy.sh/raw/main/install.sh)
```

非 root 用户会自动尝试通过 `sudo` 提权。也可以显式使用管道方式：

```bash
wget -O- https://github.com/kuss0/caddy.sh/raw/main/install.sh | sudo bash
```

只安装脚本、不立即初始化：

```bash
bash <(wget -O- https://github.com/kuss0/caddy.sh/raw/main/install.sh) --no-init
```

安装完成后会创建快捷命令 `c`，并进入维护菜单。以后直接输入：

```bash
c
```

即可通过数字选择初始化、添加站点、更新、卸载等操作。
非 root 用户执行 `c` 时，脚本会自动尝试通过 `sudo` 提权。

如果要跳过菜单并直接初始化：

```bash
bash <(wget -O- https://github.com/kuss0/caddy.sh/raw/main/install.sh) --init
```

初始化会提示输入 Cloudflare API Token。Token 会保存到 `/etc/caddy/caddy.env`，权限为 `0640`。

## Cloudflare Token 权限

建议创建只限目标 Zone 的 API Token，并授予：

- `Zone:DNS:Edit`
- `Zone:Zone:Read`

不要使用全局 API Key。

## 常用命令

打开维护菜单：

```bash
c
```

初始化 Caddy：

```bash
c init
```

添加或更新站点：

```bash
c add example.com 8080
```

这会生成类似配置：

```caddy
example.com {
    import CF_CERT
    reverse_proxy 127.0.0.1:8080
}
```

查看已启用站点：

```bash
c list
```

禁用站点：

```bash
c remove example.com
```

更新 Cloudflare Token：

```bash
c set-token
```

校验并重载：

```bash
c reload
```

更新脚本自身：

```bash
c self-update
```

更新 Caddy 二进制到脚本默认版本：

```bash
c upgrade-caddy
```

更新 Caddy 到指定版本：

```bash
c upgrade-caddy v2.11.4
```

卸载 Caddy，保留配置和证书数据：

```bash
c uninstall
```

彻底卸载，同时删除 `/etc/caddy`、`/var/lib/caddy`、快捷命令 `c` 和 caddy 用户/组：

```bash
c uninstall --purge
```

`--purge` 会要求输入 `DELETE` 二次确认。非交互环境需要显式设置：

```bash
CADDY_ASSUME_YES=1 c uninstall --purge
```

## 固定 Caddy 版本

脚本默认固定一个 Caddy 版本。需要指定版本时：

```bash
CADDY_VERSION=v2.11.4 /usr/local/bin/caddy.sh init
```

## 文件位置

- Caddy 二进制：`/usr/local/bin/caddy`
- 主配置：`/etc/caddy/Caddyfile`
- 站点配置：`/etc/caddy/conf.d/*.caddy`
- 禁用配置：`/etc/caddy/disabled/`
- 环境变量：`/etc/caddy/caddy.env`
- systemd 服务：`/etc/systemd/system/caddy.service`
- 数据目录：`/var/lib/caddy`

## 安全行为

- 如果 80/443 已被非 Caddy 进程占用，`init` 会直接失败。
- 安装器和快捷命令支持非 root 自动 sudo；没有 sudo 时会明确报错。
- 已存在的非托管 `/etc/caddy/Caddyfile` 或 `caddy.service` 不会被覆盖，除非使用 `init --force`。
- 覆盖已托管文件前会自动备份。
- `self-update` 会先校验新脚本语法，再覆盖当前脚本，并保留 `.bak.*` 备份。
- `upgrade-caddy` 会备份旧 Caddy 二进制；如果已初始化服务，会更新后自动校验并重载，失败时回滚二进制。
- `uninstall` 默认保留配置、数据和快捷命令 `c`；只有确认后的 `uninstall --purge` 会删除配置、证书数据、快捷命令 `c` 和 caddy 用户/组。
- `init` 下载 Caddy 成功后才写入配置；如果启动失败，会回滚本次改动的 `caddy.env`、`caddy.service` 和 `Caddyfile`。
- Cloudflare Token 输入时不会回显。
- `set-token` 成功后会删除临时旧 Token 备份，避免旧密钥长期残留。
