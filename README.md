# sbc-dnsmgr

> [鼠宝财](https://blog.mopush.cn) · 一键部署 [dnsmgr](https://github.com/netcccyun/dnsmgr) 聚合 DNS 管理系统（VPS / 云服务器，Docker）

给 [dnsmgr（彩虹聚合DNS管理系统）](https://github.com/netcccyun/dnsmgr) 配套的一键部署脚本：**一条命令**在干净的 Linux 服务器上把面板和数据库跑起来 —— 装 Docker、自动补 swap、生成随机数据库密码、拉起 MySQL 与面板、等健康检查通过，最后把「安装向导地址 + 向导要填的数据库信息」直接打在屏幕上。

脚本不碰上游代码，也不在宿主机上装 PHP / Nginx / MySQL —— 所有东西都在容器里，**卸载就是删目录**。

[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20Docker-blue)
![Upstream](https://img.shields.io/badge/upstream-dnsmgr-orange)

---

## 目录

- [dnsmgr 是什么](#dnsmgr-是什么)
- [这个脚本做什么](#这个脚本做什么)
- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [安装向导（装完填这些）](#安装向导装完填这些)
- [环境变量](#环境变量)
- [执行流程](#执行流程)
- [部署后的目录结构](#部署后的目录结构)
- [常用运维命令](#常用运维命令)
- [升级](#升级)
- [数据备份与恢复](#数据备份与恢复)
- [常见问题](#常见问题)
- [安全建议](#安全建议)
- [其他部署方式（不走本脚本）](#其他部署方式不走本脚本)
- [卸载](#卸载)
- [合规与协议](#合规与协议)
- [License](#license)

---

## dnsmgr 是什么

一个 **DNS 解析的集中控制台**。注意它自己不做 DNS 解析（不是 BIND / PowerDNS 那种域名服务器），而是调用各家云厂商的 API，把解析记录改掉 —— 相当于「DNS 界的宝塔面板」。

| 能力 | 说明 |
| --- | --- |
| 聚合管理 | 一个面板管多家平台：阿里云、腾讯云 DNSPod、华为云、百度云、火山引擎、京东云、青云、西部数码、宝塔、Cloudflare、AWS Route 53、Namesilo、Spaceship、PowerDNS、Technitium、HE.net、dynv6、GoEdge、DNSLA 等 |
| 多用户 | 给每个用户分配不同的域名权限，可开 API 和免登录链接，方便 IDC 系统对接 |
| 容灾切换 | 支持 ping / tcp / http(s) 检测，异常时自动暂停或修改解析，并发送通知 |
| 定时切换 | 指定时间或周期，自动修改 / 开启 / 暂停 / 删除解析记录 |
| CF 优选 IP | 自动获取 Cloudflare 优选 IP 并更新到解析记录 |
| SSL 证书 | 从 Let's Encrypt 等渠道申请证书，并自动部署到面板 / 云服务商 / 服务器 |
| 通知渠道 | 邮件、微信公众号、Telegram、钉钉、飞书、企业微信、QQ 机器人 |

## 这个脚本做什么

| 步骤 | 内容 |
| --- | --- |
| 1/7 检查环境 | 校验 root、识别发行版与架构、检查磁盘；**内存不足 4GB 且没有 swap 时自动加 2GB swap**；检查端口是否被占用（是自己容器占用则放行，方便重复执行） |
| 2/7 安装 Docker | 依次探测 **5 个 Docker 软件源**（腾讯云内网 / 腾讯云公网 / 阿里云 / 中科大 / 官方），要求 `gpg` 和 `dists/<codename>/Release` 都能取到才用；装完自动配镜像加速并限制容器日志大小 |
| 3/7 生成配置 | 随机生成 MySQL root 密码与面板用数据库密码（`openssl rand -hex 16`，每次全新安装都不同）；写 `docker-compose.yml` 与 `.credentials`（都是 600） |
| 4/7 拉取镜像 | 优先从**华为云 SWR** 拉（国内快），失败自动退回 Docker Hub（走第 2 步配的加速） |
| 5/7 启动数据库 | MySQL 5.7 容器 + 健康检查，自动建库建用户，**并实测该账号能不能登录** |
| 6/7 启动面板 | 面板容器 + 健康检查，校验程序是否落到 `/app/www/public/index.php`，列出容器内进程 |
| 7/7 汇总 | 打印面板地址、目录、凭据文件，以及**安装向导里要填的数据库信息**（放在最底部，命令跑完一眼能看到） |

**实测**：Ubuntu 22.04.5 LTS / x86_64 / 2 vCPU / 1.9GB 内存，从零到面板可访问约 **2~3 分钟**（其中拉镜像约 240MB）。运行起来占内存约 **280MB**（面板 ~84MB + MySQL ~194MB），2GB 内存的机器完全够用。

**可重复执行**：脚本是幂等的 —— 已经装过的机器再跑一次，会**复用原数据库密码**（不会重新生成导致密码对不上）、保留数据，只做健康检查与补齐。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 系统 | Linux（需要 systemd），Ubuntu 22.04 / Debian 12 已实测 |
| 权限 | root（或 `sudo`） |
| 内存 | 建议 ≥ 1GB；低于 4GB 且无 swap 时脚本自动补 2GB swap |
| 磁盘 | ≥ 4GB 可用（镜像约 240MB，其余留给 MySQL 数据与证书） |
| 架构 | `amd64` 或 `arm64`（arm64 会自动把 MySQL 换成 `mariadb:10.6`） |
| 端口 | 默认 `8081`，需在云厂商**安全组放行**，否则外网访问不到 |
| 网络 | 能访问 Docker 软件源和镜像仓库（国内源与加速已内置） |

## 快速开始

### 第一步：下载并执行

```bash
curl -fsSL -o /tmp/dnsmgr.sh https://raw.githubusercontent.com/shubaocai/sbc-dnsmgr/main/install_dnsmgr.sh && sudo bash /tmp/dnsmgr.sh
```

`raw.githubusercontent.com` 在国内时通时不通，可以换 jsDelivr：

```bash
curl -fsSL -o /tmp/dnsmgr.sh https://cdn.jsdelivr.net/gh/shubaocai/sbc-dnsmgr@main/install_dnsmgr.sh && sudo bash /tmp/dnsmgr.sh
```

也可以 clone 下来跑：

```bash
git clone https://github.com/shubaocai/sbc-dnsmgr.git
cd sbc-dnsmgr
sudo bash install_dnsmgr.sh
```

### 第二步：打开安装向导

脚本跑完会打印这样的信息（节选）：

```
  ▸ 安装向导：  http://<你的公网IP>:8081/
    项目目录：  /opt/dnsmgr
    挂载目录：  /opt/dnsmgr/app（程序与配置）、/opt/dnsmgr/mysql（数据库）
    凭据文件：  /opt/dnsmgr/.credentials（600，那串密码也在里面）

  ▸ 向导里这样填（其它留默认）：
      数据库主机：dnsmgr-mysql    端口：3306
      数据库名：  sbc_dnsmgr
      数据库用户：sbc_dnsmgr
      数据库密码：<随机生成，脚本会打印>
      管理员账号 / 密码：自己设，装完立刻开二次验证（TOTP）
```

## 安装向导（装完填这些）

浏览器打开 `http://<你的公网IP>:8081/`，会跳到安装页，按下面填（其它留默认）：

| 字段 | 填什么 |
| --- | --- |
| 数据库主机 | `dnsmgr-mysql` ⚠️ **不能填 `localhost` 或 `127.0.0.1`**，那是容器自己，会报「数据库连接失败」 |
| 数据库端口 | `3306` |
| 数据库名 | `sbc_dnsmgr` |
| 数据库用户 | `sbc_dnsmgr` |
| 数据库密码 | 脚本结尾打印的那串；也可 `cat /opt/dnsmgr/.credentials` |
| 表前缀 | 默认 `dnsmgr_`，不用改 |
| 管理员账号 / 密码 | 自己设，**装完立刻开启 TOTP 二次验证** |

装完的地址：面板首页就是登录页（`http://<你的公网IP>:8081/`），没有单独的 `/admin`。

## 环境变量

写成环境变量放在命令前即可，全部可选：

```bash
DNSMGR_PORT=9090 DNSMGR_DIR=/srv/dnsmgr bash install_dnsmgr.sh
```

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `DNSMGR_PORT` | `8081` | 面板对外端口 |
| `DNSMGR_DIR` | `/opt/dnsmgr` | 安装目录 |
| `DNSMGR_IMAGE` | 华为云 SWR 镜像 | 指定镜像地址（默认失败自动退回 Docker Hub） |
| `USE_MARIADB` | `0` | 设为 `1` 用 `mariadb:10.6`（arm64 会自动启用） |
| `SKIP_DOCKER_INSTALL` | `0` | 设为 `1` 表示机器上已装 Docker，跳过安装步骤 |
| `REGISTRY_MIRROR` | `https://mirror.ccs.tencentyun.com` | Docker 镜像加速；设为空则不配置 |
| `DOCKER_APT_MIRROR` | 自动探测 5 个源 | 指定 Docker 软件源 |
| `LOG_FILE` | `/var/log/dnsmgr-install.log` | 安装日志路径 |

查看完整说明：`bash install_dnsmgr.sh --help`

## 执行流程

```
检查环境（系统/架构/磁盘/内存+swap/端口）
   ↓
装 Docker（5 个国内源探测 + 镜像加速）
   ↓
生成随机密码 → 写 docker-compose.yml 与 .credentials
   ↓
拉镜像（华为云 SWR → Docker Hub 回退）
   ↓
起 MySQL（健康检查 + 建库 + 实测登录）
   ↓
起面板（健康检查 + 程序落位校验）
   ↓
打印面板地址 / 目录 / 向导要填的信息
```

**定时任务是镜像内置的，不用在宿主机配 cron**：

- 容器里 `crond` 每分钟执行 `php think certtask` —— 证书申请 / 续期 / 部署
- `supervisord` 常驻 `php think dmtask` —— 容灾切换、定时切换、CF 优选
- 走完安装向导之前 dmtask 会反复重启（读不到 `.env`），属正常现象，装完自动稳定

## 部署后的目录结构

```
/opt/dnsmgr/
├── docker-compose.yml     # 面板 + MySQL 编排（权限 600）
├── .credentials           # 数据库账号密码（权限 600）
├── app/                   # 挂载到容器 /app：程序、配置、runtime、.env
│   └── www/               #   程序本体（public 为运行目录）
└── mysql/                 # MySQL 数据目录

/var/log/dnsmgr-install.log   # 安装日志
```

容器组成：

| 容器 | 内容 |
| --- | --- |
| `dnsmgr-web` | nginx + PHP 8.3 FPM + Swoole 常驻任务 + crond（监听容器内 80） |
| `dnsmgr-mysql` | MySQL 5.7（**不对外暴露端口**，只有面板容器能连） |

## 常用运维命令

都在 `/opt/dnsmgr` 下执行：

```bash
docker compose ps                    # 查看状态
docker compose logs -f dnsmgr-web    # 看面板日志
docker compose logs -f dnsmgr-mysql  # 看数据库日志
docker compose restart dnsmgr-web    # 重启面板
docker compose down                  # 停服（数据保留）
```

## 升级

```bash
bash install_dnsmgr.sh --upgrade
```

做的事：拉取最新镜像 → 清除容器内首次运行标记 → 用新代码覆盖程序目录 → 重建面板容器。**数据库、`.env`、上传的证书等数据都保留**。

> 上游更新很勤（几个月一个版本），升级前建议先备份数据库。

## 数据备份与恢复

**备份数据库**：

```bash
docker exec dnsmgr-mysql sh -c "exec mysqldump -uroot -p$(awk -F': ' '/^数据库 root 密码/{print $2}' /opt/dnsmgr/.credentials) --databases sbc_dnsmgr" > sbc_dnsmgr-$(date +%F).sql
```

**备份程序与配置**（含 `.env`、证书、runtime 数据）：

```bash
tar czf dnsmgr-app-$(date +%F).tar.gz -C /opt/dnsmgr app
```

**恢复**：

```bash
# 1) 恢复程序与配置
tar xzf dnsmgr-app-YYYY-MM-DD.tar.gz -C /opt/dnsmgr
# 2) 恢复数据库
docker exec -i dnsmgr-mysql sh -c "exec mysql -uroot -p$(awk -F': ' '/^数据库 root 密码/{print $2}' /opt/dnsmgr/.credentials)" < sbc_dnsmgr-YYYY-MM-DD.sql
# 3) 重启面板
cd /opt/dnsmgr && docker compose restart dnsmgr-web
```

## 常见问题

**浏览器打不开面板 / 一直转圈？**

先确认云厂商**安全组放行了 `DNSMGR_PORT`**（默认 8081），这是最常见的原因。然后在服务器上自测：

```bash
curl -I http://127.0.0.1:8081/          # 本机应该返回 302 跳 /install
cd /opt/dnsmgr && docker compose ps     # 两个容器都应是 healthy
```

> 注意：云服务器**无法用公网 IP 访问自己**（回环问题），自测请用 `127.0.0.1`，从外部判断要用另一台机器。

**向导报「数据库连接失败」？**

三个填写项逐个核对：

1. 主机必须是 `dnsmgr-mysql`（写 `localhost` / `127.0.0.1` 一定失败 —— 那是面板容器自己）
2. 库名与用户名都是 `sbc_dnsmgr`
3. 密码从 `/opt/dnsmgr/.credentials` 复制，注意别多带空格

**向导提示「当前已经安装成功，如果需要重新安装，请手动删除根目录 .env 文件」？**

说明已经装过了。要重装：删 `/opt/dnsmgr/app/www/.env`，并清空数据库里的表（或直接 `docker compose down -v` 后重跑脚本，连数据一起清掉）。

**容器日志里 dmtask 一直重启？**

正常现象。面板安装完成前读不到 `.env`，supervisord 会一直重启它；走完安装向导就稳定了。

**「域名管理」页面报 500，日志是 `Call to a member function getDomainList() on false`？**

上游的一个小 bug：面板里**还没有任何「域名账户」**时，该接口会拿一个空账户去查域名列表。先去「域名账户」里添加一个（选平台、填那家的 API 密钥），这个报错就不再出现。

**镜像拉不动？**

指定镜像或用其他源：

```bash
DNSMGR_IMAGE=netcccyun/dnsmgr:latest bash install_dnsmgr.sh    # 走 Docker Hub（用已配的加速）
REGISTRY_MIRROR= DNSMGR_IMAGE=<你的镜像地址> bash install_dnsmgr.sh
```

**重复执行脚本会不会把密码改了？**

不会。检测到已有安装（`docker-compose.yml` + `mysql/` 数据目录都在）时，脚本会从 compose 里读回原密码沿用，数据不受影响。

**忘记管理员密码？**

面板密码用 PHP `password_hash` 存储，不能从数据库直接读出明文。稳妥做法是备份数据后重装面板（删 `.env` + 清库），或在面板里用其他管理员账号重置。**建议装完就把密码记进密码管理器，并开启 TOTP。**

**能不能用已有的外部 MySQL，不起 MySQL 容器？**

目前脚本固定自带 MySQL 5.7 容器（省心优先）。要接外部库，需要自己改 `docker-compose.yml`（去掉 `dnsmgr-mysql` 与 `depends_on`）并在向导里填你外部库的地址；注意面板要求 MySQL ≥ 5.6、字符集 `utf8mb4`。

## 安全建议

这个面板里会保存**各家云平台的 API 密钥**（等于域名的最高权限），还能通过 SSH / FTP 往服务器部署证书，属于高价值目标：

1. **加一层 HTTPS 反代**（Nginx/Caddy + Let's Encrypt），不要长期裸 HTTP 暴露
2. **强密码 + 开启 TOTP 二次验证**
3. 尽量**限制来源 IP**（安全组只放行你的固定 IP），或只在内网访问
4. 定期看面板的「日志」与操作记录；定期备份数据库
5. 容器里的 MySQL **没有对宿主机暴露端口**，这是有意为之，不要随意加 `ports`

## 其他部署方式（不走本脚本）

上游支持宝塔、Kangle、虚拟主机等 PHP 环境部署（见 [上游 README](https://github.com/netcccyun/dnsmgr)），但有几个坑要注意：

| 坑 | 说明 |
| --- | --- |
| 运行目录必须设为 `public` | 项目根目录有 `.env`（数据库密码）和 `app/`（源码 + SQL）。上游 README 给的 Nginx 规则写的是 `location ~* (runtime\|application)/ { return 403; }`，其中 `application` 是 ThinkPHP 5 时代的目录名，本项目已改名 `app` —— **那条规则挡不住 `app/`**，所以务必把网站运行目录指到 `public` |
| 自动化功能会打折 | 容灾切换、定时切换、CF 优选、证书自动续期都依赖「常驻进程 + cron」。只有 PHP-CGI 的虚拟主机没有这两个，功能基本只能手动点；要完整功能请用 VPS / Docker |
| 扩展要求偏多 | 除 `curl / gd / mbstring / openssl / pdo_mysql / zip` 外，还需要 `sockets`、`ftp`、`ssh2`（PECL）；缺 `ssh2` 只影响「SSH 方式部署证书」。源包还需要 composer 装依赖（PHP ≥ 8.2），Release 包已自带 `vendor` |
| 官方 `docker run` 示例的卷挂法有坑 | 官方示例把卷挂在 `/app/www`，而镜像的 entrypoint 用 `cp -a /usr/src/www /app/` 铺程序，会导致目录被套成 `/app/www/www`、面板 404。本脚本改为挂载 **`/app`** 就是为了避开这个问题（已实测） |

## 卸载

```bash
cd /opt/dnsmgr && docker compose down    # 停服，数据保留
rm -rf /opt/dnsmgr                       # 连数据一起删
```

想连 Docker 一起清理（仅当你不再用它）：

```bash
docker rmi swr.cn-east-3.myhuaweicloud.com/netcccyun/dnsmgr:latest mysql:5.7
```

## 合规与协议

- **dnsmgr** 是上游开源项目：MIT License © 2024 消失的彩虹海（[github.com/netcccyun/dnsmgr](https://github.com/netcccyun/dnsmgr)）。本项目只是部署脚本，不分发也不修改上游代码。
- 面板会保存第三方云平台凭据并代为操作解析与证书，**请自行评估合规性与安全风险**，尤其注意别把它长期裸奔在公网上。
- 上游仓库的 `composer.json` 里 `license` 字段写的是 `Apache-2.0`，而仓库 `LICENSE` 文件是 MIT —— 两处不一致，商用前请自行确认。

## License

[MIT](LICENSE) © 2026 [鼠宝财](https://blog.mopush.cn)
