# EasyTier + SSH 一键安装

面向 Ubuntu 20.04+ / Debian 11+，支持 x86_64、ARM64，需要 root 和 `/dev/net/tun`；支持 systemd 主机及 tini 容器。固定安装 EasyTier 2.6.4，校验官方发布包 SHA-256，安装 OpenSSH；systemd 主机配置开机启动，容器使用 SysV SSH 启动脚本和独立 Supervisor 管理进程。

公开仓库不包含任何实际网络名称、组网密钥、服务器地址、机器清单或 SSH 公钥。加入你的现有网络需要你自己保管的私有 JSON 文件。不要把它上传到 GitHub、粘贴到 Issue 或放进命令参数。

## 推荐：先安装，后入网（无需上传文件）

在目标 Ubuntu / Debian 服务器执行：

```bash
curl -fsSLO https://raw.githubusercontent.com/yantoumu/easytier-bootstrap/main/zsh.sh && bash zsh.sh
```

此时只安装 EasyTier 并开启 SSH 密码认证，不需要任何组网配置。EasyTier 服务在完成入网配置后才启动。SSH 使用目标机器已有账号和密码；缺少密码时通过服务器控制台执行 `sudo passwd 用户名`。

准备连接时执行：

```bash
sudo easytier-join
```

按提示输入组网名称、隐藏的组网密码、CIDR 网段、引导节点 URI 和本机未占用的组网 IP。配置仅保存在本机受限目录。已有配置时重复执行只重试启动和连接检查，不覆盖身份；错误配置需在本地控制台检查处理。

以下是可选的私有文件导入方式，不是安装前置条件。

## 1. 从已有节点导出私有入网文件

在已有节点下载仓库，使用 Python 3.11+ 读取原来的 EasyTier TOML：

```bash
git clone https://github.com/yantoumu/easytier-bootstrap.git
cd easytier-bootstrap
sudo python3 profile.py export \
  --source /path/to/existing-config.toml \
  --subnet YOUR_EXISTING_CIDR \
  --output "$HOME/network.private.json"
```

`--subnet` 填实际网段，例如 `192.168.70.0/24`（仅为虚构示例）；如果源配置的 IPv4 已含前缀可省略。导出文件权限为 0600，并交回执行 sudo 的用户。已有输出文件不会覆盖。导出只保留网络身份、引导节点地址、网段和源节点保留地址，不复制源节点 IP、代理路由、出口网关、ACL 或身份文件。特殊安全模式会拒绝自动导出，需另行适配。

用可信的文件传输方式把该文件送至目标服务器，例如已有 SSH 通道：

```bash
scp "$HOME/network.private.json" admin@SERVER:~/network.private.json
```

目标服务器还没有 SSH 时，通过云控制台或本地终端传入文件。安装后可以删除该临时 JSON；运行配置保存在 `/etc/easytier-bootstrap/config.toml`，权限 0600。

## 2. 在新服务器一键安装

先选定一个未被现有设备使用的同网段 IP。脚本会拒绝源节点地址、网段外地址及网络/广播地址；**不会自动判定其他在线或离线设备是否占用该 IP**，请检查整个网络的地址分配记录。

目标机器已有 curl 时：

```bash
curl -fsSL https://raw.githubusercontent.com/yantoumu/easytier-bootstrap/main/install.sh -o /tmp/easytier-install.sh && sudo bash /tmp/easytier-install.sh --profile "$HOME/network.private.json" --ip NEW_UNUSED_IP
```

没有 curl 时，先通过系统包管理器安装 `curl ca-certificates`。也可以下载整个仓库运行。安装脚本自动下载匹配的辅助工具，并验证其固定 SHA-256；主分支升级期间若校验不匹配，应重新下载脚本。

需要给已有用户添加登录公钥：

```bash
sudo bash /tmp/easytier-install.sh \
  --profile "$HOME/network.private.json" --ip NEW_UNUSED_IP \
  --ssh-user admin --ssh-key /path/to/id_ed25519.pub
```

提供已有用户和单行 OpenSSH 公钥，不传私钥。默认开启 SSH 密码认证，使用目标机器已有账号和密码；未设置密码时，在服务器执行 `sudo passwd 用户名`。公钥配置完全可选。保留现有 authorized_keys，不创建用户、不修改密码，不改变 root 登录策略。若该用户没有可用密码或密钥，启动 SSH 不代表能登录。已有 `AllowUsers`、`Match`、自定义 `AuthorizedKeysFile` 等规则仍然生效。

本脚本用于新机器安装，发现已有安装、运行中的 EasyTier 或已有二进制会停止，不覆盖现网配置。失败后可能留下部分安装结果；请通过本地/云控制台检查原因，再决定是否清理后重新安装。

## 3. 状态和登录

```bash
bash /usr/local/lib/easytier-bootstrap/services.sh status
sudo easytier-cli peer
ssh admin@NEW_UNUSED_IP
```

安装结束前检查两个服务运行、指定虚拟 IP、至少一个远端组网节点以及 SSH 的 IPv4 监听。最多等待约 60 秒连接组网，失败返回非零状态，已安装服务仍保留便于排查；服务日志可能含私有地址或配置错误详情，请不要公开粘贴。

SSH 端口沿用现有配置，安装结束会输出端口。脚本明确设置 `PasswordAuthentication yes` 和 `PermitEmptyPasswords no`，其他认证限制与监听策略保留；已有 `Match` 或多因素 `AuthenticationMethods` 规则可能仍限制密码登录。若 SSH 只监听某个物理网卡地址，脚本会失败提示，需调整后重试。

- 若 UFW 已启用，只在 `etvpn0` 虚拟接口放行已有 SSH 端口，不新增公网放行规则，也不关闭防火墙。
- 若没有启用防火墙，OpenSSH 默认可能监听全部网卡，公网可达性取决于已有规则与云安全组；本脚本不把 SSH 强制限制为仅组网可用。
- nftables、iptables 自定义规则、云安全组需自行放行 VPN 接口的 SSH 流量；脚本不改写它们。
- EasyTier 使用出站引导连接和打洞；严格出站防火墙可能阻断入网。不会自动开放公网 11010 入站。
- RPC 管理接口固定监听 `127.0.0.1:15888`。若端口冲突，需先处理冲突服务。

## 验证范围

开发机为 macOS。已进行语法检查、配置导出/生成探针、官方配置契约比对以及调用链与对抗式审查；尚未在全新 Ubuntu/Debian 主机执行完整 root 安装，也未验证你的实际私有网络凭据。首次部署请从可用的本地/云控制台执行，并以脚本最终检查和实际 SSH 登录为准。

## tini / 非 systemd 容器

安装会自动选择容器模式，不再要求 systemd。入网仍需宿主提供 `/dev/net/tun` 及 `NET_ADMIN` 等必要权限；设备文件存在不等于具备权限。容器内 root 不能自行授予宿主能力。

Supervisor 日志和套接字位于 root 专用目录，不开放 HTTP 管理端口。容器销毁会丢失未持久化数据；容器重启后，在平台启动脚本中执行：

```bash
bash /usr/local/lib/easytier-bootstrap/services.sh ssh-start
# 已配置组网后执行，复用原配置：
easytier-join
```

容器 SSH 若需从外网访问，还需要平台映射 SSH 端口；本安装器无法修改宿主端口映射。容器适配已做静态调用链与配置检查，尚未在用户的目标容器上实测。
