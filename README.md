# ix-onekey

HaloCloud IX 云联网「路由模式」一键组网脚本：在香港机上执行一次，自动完成
香港端 SNAT + 内地端策略路由 + 默认路由切换，并内置**双层自动守护**，
双机重启后可自愈，不会像原版 `sdwan.sh --sbmode` 那样失效。

## 一键指令（在香港机 root 执行，复制即用）

```bash
# ① 先看计划（只读探测，不改任何东西）
bash <(curl -sL https://raw.githubusercontent.com/iiiiiiiii7125-art/ix-onekey/main/ix-onekey.sh) --sbmode --qh-ip <内地机内网IP> --dry-run

# ② 正式安装
bash <(curl -sL https://raw.githubusercontent.com/iiiiiiiii7125-art/ix-onekey/main/ix-onekey.sh) --sbmode --qh-ip <内地机内网IP>

# ③ 查看状态
bash <(curl -sL https://raw.githubusercontent.com/iiiiiiiii7125-art/ix-onekey/main/ix-onekey.sh) --qh-ip <内地机内网IP> --status

# ④ 一键卸载（恢复内地机原始默认路由，清两端配置）
bash <(curl -sL https://raw.githubusercontent.com/iiiiiiiii7125-art/ix-onekey/main/ix-uninstall.sh) --qh-ip <内地机内网IP>
```

备注：

- 全程只在**香港机**执行，内地机只需要 SSH 开着、root 能登录（密码或密钥均可，密钥用 `--ssh-key /root/.ssh/id_ed25519` 代替密码环境变量）
- `<内地机内网IP>` 填和香港机同内网的那台内地机 IP；脚本通用、零硬编码，其他组网换个 IP 就能用
- 装完建议双机同时重启一次验收：等 3~5 分钟，内地机 `curl -s https://ipinfo.io/ip` 应为香港公网 IP，且公网 SSH 能连回内地机
- 密码在运行时由你亲自在终端输入（不回显、只输一次、全程复用、不落盘），脚本本身不含任何真实 IP 或凭据

## 为什么不用原版

原版 `bash <(curl -sL https://filecdn.astroqore.org/haloix/sdwan.sh) --sbmode` 在真实双机上暴露的问题：

- 号称免交互，SSH 用户/端口/认证/密码仍要逐个回答（`ensure_remote_context` 没有 sbmode 分支）
- 外网网关取不到时按 `x.x.x.1` **猜**，猜错还写死进恢复脚本，导致每次恢复后内地机公网回程（SSH）被打断
- 开机恢复只 `sleep 10` + 只 ping 一次香港：双机同时重启时香港稍慢，内地机就回退默认路由且**永不切回**
- nft 用 `iif/oif`、整表覆盖 `/etc/nftables.conf`、全局 `FORWARD DROP`、`chattr +i` 锁 DNS 等副作用

## 本脚本的设计

- **参数免交互、密码亲自输**：参数走命令行 / 配置文件；内地机密码运行时在终端提示输入（不回显、输一次全程复用、不落盘），不用把密码写进命令或环境变量
- **网关绝不猜**：只用改动前的真实默认路由或原始路由快照，取不到就停
- **网卡用 `ip route get` 锚定**，不用启发式优先级
- **切默认路由前武装死人开关**（默认 180s）：控制器用新 SSH 验出口通过才解除，切错自动回滚
- **重启三层自愈**：开机恢复等网卡/等香港可达（≤120s）→ 内地机看门狗每 2 分钟全量收敛（默认路由 + ix_return + 标记表）→ 香港机守护定时器本机自检 + SSH 远程纠偏
- nft 一律 `iifname/oifname`；只动自有表与 `sysctl.d` 文件；不锁 DNS

## 安装（在香港机 root 执行）

前置：内地机 SSH 已开启、root 可登录；记下内地机内网 IP。

```bash
# 先看计划（只读探测，不改任何东西）
bash <(curl -sL https://raw.githubusercontent.com/iiiiiiiii7125-art/ix-onekey/main/ix-onekey.sh) --sbmode --qh-ip <内地机内网IP> --dry-run

# 正式安装
bash <(curl -sL https://raw.githubusercontent.com/iiiiiiiii7125-art/ix-onekey/main/ix-onekey.sh) --sbmode --qh-ip <内地机内网IP>
```

也可用密钥：`bash ix-onekey.sh --qh-ip <IP> --ssh-key /root/.ssh/id_ed25519`

状态查看：`bash ix-onekey.sh --qh-ip <IP> --status`（同样需要密码环境变量或密钥）

## 卸载

```bash
bash <(curl -sL https://raw.githubusercontent.com/iiiiiiiii7125-art/ix-onekey/main/ix-uninstall.sh) --qh-ip <内地机内网IP>
```

卸载会先把内地机默认路由恢复到安装前快照，再清理两端的表、服务、看门狗、守护与状态文件。

## 验收建议

装完后故意双机同时重启一次，等 3~5 分钟，在内地机验证：

```bash
curl -s https://ipinfo.io/ip   # 应为香港机公网 IP
ip route show default          # 应为 via <香港内网IP>
```

再从公网 SSH 连一次内地机，能连即全部通过。

## 文件

- `ix-onekey.sh` — 一键安装/状态/回滚（`--dry-run` / `--status` / `--rollback`）
- `ix-uninstall.sh` — 独立卸载脚本
