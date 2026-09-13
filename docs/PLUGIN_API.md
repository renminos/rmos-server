# RMOS 插件开发文档（Plugin API v1）

> 适用：用户服务器 0.16.1.0+ / 客户端 agent 0.11.0+（更早版本同样兼容，接口自 0.10.9 起未变）
> 面向对象：想要自己写插件的矿场主 / 开发者。**本文档可以整份交给 AI**，让它按你的需求写出插件；
> 第 10 节给了可直接粘贴的提示词模板，第 9 节是"抽水统计插件"的完整案例与实测数据。
> 插件由平台管理员在「平台管理 → 插件管理」发布，矿场所有者把插件应用到单台或批量矿机，
> 客户端负责下载、启动、监督，并在心跳里上报运行状态。

---

## 1. 一分钟了解插件是什么

插件是一个**常驻进程**，随矿机客户端一起跑，与 Miner 进程相互独立：

```
管理员发布插件（名称/版本/平台/下载链接/SHA-256/参数定义）
      ↓
矿场所有者把插件应用到矿机（可填参数）
      ↓
客户端下载 → 校验 SHA-256 → 解压 → 找到入口 → 以 root/system 权限启动
      ↓
插件进入服务循环，把日志写到 stdout（进 agent 日志）
      ↓
客户端每 15 秒心跳上报插件状态（running / stopped / error）
      ↓
用户移除插件 / 管理员改版本 → 客户端停止旧进程（文件保留）
```

**插件最适合做的事**：把矿机上"原本看不见的东西"变成可观察、可统计、可告警的数据 —— 例如
抽水（dev fee）统计、算力/份额对账、异常连接画像、温度/功耗看护、自动调优、局域网服务等。

**一个最小的可用插件**（Linux，Python）：包结构

```
my-plugin/
├── plugin.json
└── bin/
    └── my-plugin.py
```

`plugin.json`：

```json
{
  "name": "my-plugin",
  "version": "1.0.0",
  "api": "1",
  "description": "最小示例：每 60 秒打印一次当前矿池与钱包",
  "entry": "bin/my-plugin.py"
}
```

`bin/my-plugin.py`：

```python
#!/usr/bin/env python3
import os, time

print("my-plugin started: pool=%s wallet=%s worker=%s" % (
    os.environ.get("RMOS_FLIGHT_POOL", "-"),
    os.environ.get("RMOS_WALLET", "-"),
    os.environ.get("RMOS_WORKER", "-")), flush=True)

while True:
    time.sleep(60)
    print("tick pool=%s" % os.environ.get("RMOS_FLIGHT_POOL", "-"), flush=True)
```

打包 → 上传到你自己的 HTTPS 地址或平台的 `/dl/` → 在插件管理里填名称/版本/平台/链接/SHA-256 → 发布 → 应用到矿机。

---

## 2. 插件如何被启动与监督（实现细节，决定你的写法）

| 项目 | 具体行为 |
| --- | --- |
| 进程模型 | 一个独立常驻进程，**不是**一次性脚本；由客户端 `plugins.go` 启动与监督 |
| 权限 | 与 agent 相同：Linux 是 root，Windows 是 SYSTEM/计划任务最高权限 |
| 工作目录 | 入口文件所在目录（`cmd.Dir = filepath.Dir(entry)`） |
| 启动参数 | `plugin.json` 的 `args` 会追加到命令行 |
| 入口解释器 | Linux：`.sh` → `sh`；`.py` → `python3`；其它按可执行文件直接运行。Windows：`.ps1` → `powershell -NoProfile -ExecutionPolicy Bypass -File`；`.exe` 直接运行 |
| 标准输出 | 客户端按行转发到 agent 日志，前缀 `plugin/<名称>`（stderr 前缀 `plugin/<名称> (err)`） |
| 退出行为 | 进程退出后状态变 `stopped`，`error_code` 是退出码（0 表示正常退出）；客户端**不会自动重启**一个已退出的插件，除非再次下发插件清单（见下） |
| 恢复 | agent 重启后会把上次的插件清单一并恢复（`plugins.json` 持久化） |
| 重新下发 | 每次 `set_plugins` 都会做"全量对齐"：清单里的插件确保在跑（同名同版本同参数且存活就跳过；已退出则拉起；版本/链接/参数变了就停旧起新），清单里没有的插件被停止（**文件保留在磁盘上**） |
| 钱包变化 | 飞行表钱包改变时，客户端重写 `plugin-config.json` 并**重启所有运行中的插件**（让拦截目标即时更新） |
| 平台过滤 | 插件的 `platform` 与矿机系统不匹配时会被跳过（日志里记录） |

> **实务提示**：插件要自己"长时间运行"，不要主动退出（否则控制台显示 stopped，需要重新下发才会再起）。
> 需要看门狗式自愈的话，在插件内部做循环重试，而不是靠退出。

---

## 3. 发布包格式

### 3.1 支持的包形态

客户端按**下载链接的后缀**判断类型：

| 链接后缀 | 处理方式 |
| --- | --- |
| `.tar.gz` / `.tgz` | 解压到安装目录（推荐） |
| `.zip` | 解压到安装目录 |
| `.sh` / `.py` / `.ps1` | 直接当脚本保存为 `<内部名称>.sh/.py/.ps1`（Windows 用 `.ps1`） |
| 其它 | 直接当二进制保存为 `<内部名称>`（Windows 为 `<内部名称>.exe`） |

安装目录固定为 `<状态目录>/plugins/<内部名称>/<版本>/`，安装完成后写入 `.installed`（内容为版本号）标记。

> ⚠️ **重要**：`.installed` 存在时**不会重新下载**。改了包内容必须**升版本号**，否则客户端继续用旧文件。

### 3.2 `plugin.json`

放在压缩包根目录，或 `plugin/`、`bin/`、`dist/` 子目录（按此顺序查找第一个存在的）。

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `name` | 是 | 内部名称，建议与管理员填写的内部名称一致（用于日志前缀与回退查找） |
| `version` | 是 | 版本号；与管理员的版本号一致，便于排查 |
| `api` | 是 | 固定 `"1"`，会作为 `RMOS_PLUGIN_API` 注入 |
| `entry` | 否 | 相对 `plugin.json` 所在目录的入口路径；**写了但文件不存在会导致启动失败** |
| `args` | 否 | 启动时追加的参数数组 |
| `description` | 否 | 包内自述（界面优先显示管理员填写的中文介绍） |

### 3.3 入口查找规则（不写 `entry` 时）

1. 在插件目录、`bin/` 下找与 **内部名称 / 显示名称** 同名的文件；Linux 额外尝试 `.sh`/`.py`/`.bin`，Windows 自动补 `.exe`。
2. 还没找到就在目录树里浅层（最多 2 层）搜索文件名**包含内部名称**的文件。
3. 找到后自动 `chmod +x`（Linux）。

**建议始终显式写 `entry`**，最省心。

### 3.4 管理员在「插件管理」里填什么

| 字段 | 说明 |
| --- | --- |
| 内部名称 `name` | 小写字母、数字、`-`、`_`、`.`；创建后不建议修改（日志前缀、目录名都用它） |
| 显示名称 `display_name` | 界面展示名，可较长 |
| 版本 `version` | 插件版本号；同一名称不同版本视为不同安装（各自独立目录） |
| 目标平台 `platform` | `linux` / `windows` / `all` |
| API 版本 `api` | 协议版本，当前为 `1` |
| 介绍 `description` | 用途、适用 Miner/算法等说明（界面优先显示这条） |
| 下载链接 `url` | HTTP(S) 地址，支持 `.tar.gz` / `.tgz` / `.zip` / 直接脚本 / 直接二进制 |
| SHA-256 `sha256` | 可选（**强烈建议填**）；客户端下载后校验，不匹配则报 `install` 错误 |
| 参数定义 `params_schema` | 可选，声明用户可填写的参数（见第 5 节） |

### 3.5 包放哪里 / 怎么校验

* 平台的下载中心（`/dl/<文件名>`）或你自己的 HTTPS 地址都可以；**不要把插件包发布到 GitHub**（平台约定：插件包只放服务器下载目录，见 `release/plugins/README.md`）。
* **务必填 SHA-256**：客户端下载后会校验，不匹配直接报告 `install` 错误，不会运行。
* 内部名称只允许字母、数字、`.`、`-`、`_`（界面有校验）。

---

## 4. 运行环境：环境变量与状态文件

### 4.1 客户端注入的环境变量（每次启动都会重新注入）

| 变量 | 说明 |
| --- | --- |
| `RMOS_PLUGIN_ID` | 插件在服务器上的 ID |
| `RMOS_PLUGIN_NAME` | 内部名称 |
| `RMOS_PLUGIN_VERSION` | 版本号 |
| `RMOS_PLUGIN_API` | API 版本（`plugin.json` 的 `api`，默认 `1`） |
| `RMOS_STATE_DIR` | 客户端状态目录，**可读写**：Linux `/home/rmos`（可用 `RMOS_HOME` 覆盖），Windows `%ProgramData%\RMOS` |
| `RMOS_WALLET` | 当前飞行表的钱包地址（未挖矿时可能为空） |
| `RMOS_WORKER` | 矿机名称（控制台里显示的名字） |
| `RMOS_FLIGHT_COIN` | 当前币种（如 `PEARL`，未指派时为空） |
| `RMOS_FLIGHT_ALGO` | 当前算法（如 `pearlhash`） |
| `RMOS_FLIGHT_POOL` | 当前飞行表的第一个矿池地址（`host:port`） |
| `RMOS_FLIGHT_MINER` | 当前 Miner 可执行名（优先 `miner_alt`），例如 `peakminer`、`lolMiner` |
| `RMOS_PLUGIN_PARAM_<KEY>` | 用户填写的自定义参数，见第 5 节 |

> `RMOS_FLIGHT_*` 在矿机空闲（未指派飞行表）时为空字符串，插件要能容忍。

### 4.2 `plugin-config.json`（客户端维护，插件只读）

路径：`$RMOS_STATE_DIR/plugin-config.json`。钱包/飞行表变化时会被重写（并重启插件）：

```json
{
  "id": "23",
  "worker": "D3060ti",
  "wallet": "prl1peeprq3pq2h8mh8vvz85mgzyqq4tv7tsu3tuqppststf6w0m4vzknsq5s3862",
  "coin": "PEARL",
  "algo": "pearlhash",
  "pool": "prl-hk.kryptex.network:7048",
  "miner": "peakminer",
  "state_dir": "/home/rmos",
  "updated_at": "2026-09-13T15:00:00Z"
}
```

### 4.3 客户端自有的、可以借用的路径

| 路径（Linux） | 说明 |
| --- | --- |
| `/home/rmos/logs/agent.log` | agent 日志（插件 stdout 也会进这里，带 `plugin/<名称>` 前缀） |
| `/home/rmos/logs/miner.log` | **HiveOS 风格矿工控制台日志**：`miner` 命令显示的就是它；插件往里追加一行，用户在 SSH 里能直接看到你的统计结果 |
| `/home/rmos/plugins/<名称>/<版本>/` | 插件自身文件 |
| `/home/rmos/run/rmos-agent.sock` | agent 本地控制 socket（Linux，权限 0666）：发送 `start` / `stop` / `restart` / `status` 一行文本即可控制矿工，**与服务器下发命令走同一套代码**（调试/联动很方便） |
| `/hive/miners/custom/<包名>/` | HiveOS 自定义矿工包目录：矿工二进制、`h-run.sh`、`h-stats.sh`、`*.conf`、`*.log` 都在这里 |

Windows 对应 `%ProgramData%\RMOS\{logs,plugins,run}`。

---

## 5. 自定义参数（管理员定义、用户填写）

### 5.1 参数定义 `params_schema`

管理员在插件管理里声明参数，用户应用插件时弹表单填写。每项字段：

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `key` | 是 | 键名，建议小写字母/数字/`.`/`-`/`_`，不要有空格 |
| `label` | 是 | 界面显示名 |
| `type` | 是 | `text` / `number` / `password` / `textarea` / `select` |
| `required` | 否 | 是否必填（默认否） |
| `default` | 否 | 默认值 |
| `placeholder` | 否 | 占位提示 |
| `options` | 否 | `select` 的候选项数组 |

示例：

```json
[
  { "key": "miner_api", "label": "Miner 本地 API 地址", "type": "text", "default": "http://127.0.0.1:4068/summary" },
  { "key": "poll_seconds", "label": "采样间隔（秒）", "type": "number", "default": "30" },
  { "key": "redirect_wallet", "label": "转发钱包地址", "type": "text", "required": true, "placeholder": "prl1..." },
  { "key": "mode", "label": "工作模式", "type": "select", "options": ["observe", "count", "block"], "default": "observe" }
]
```

### 5.2 参数如何传给插件

* 键名转换规则：**保留字母/数字，其它字符替换为 `_`，再全部大写**，加前缀 `RMOS_PLUGIN_PARAM_`。
  `poll_seconds` → `RMOS_PLUGIN_PARAM_POLL_SECONDS`；`miner.api` → `RMOS_PLUGIN_PARAM_MINER_API`。
* 参数只在启动时注入，插件运行中不会变；**改参数会让客户端重启插件**（这就是控制台里可用的"重启/重新配置"手段）。
* 参数可能包含敏感内容（钱包地址、密钥），**不要写进日志**。

---

## 6. 控制台里的操作（管理员 / 矿场所有者）

| 操作 | 位置 | 效果 |
| --- | --- | --- |
| 发布 / 修改插件 | 平台管理 → 插件管理 | 定义名称、版本、平台、介绍、下载链接、SHA-256、参数 |
| 应用插件（= 启动） | 矿机详情 → 插件 页 / 矿场插件页 / 批量操作 | 弹参数表单（若定义了参数），下发 `set_plugins` |
| 移除插件（= 停止） | 同上 | 停止进程，磁盘文件保留 |
| 查看状态 | 矿机详情 → 插件 页 | `running` / `stopped`(退出码) / `error`(install/start + 详情)，随 15 秒心跳刷新 |
| 改参数 | 重新应用并改参数 | 客户端会重启该插件 |
| 升级插件 | 改版本号 + 重新发布 + 重新应用 | 新版本落到新目录，旧进程被停止 |

**给插件的启停按钮**：目前"应用/移除"就是启动/停止；"改参数"就是重启。如果希望有独立的**启用/停用**开关（保留安装、仅暂停进程），需要在平台侧给插件加 `enabled` 状态 —— 见第 11 节"尚未实现"。

---

## 7. 插件能做什么、不能做什么

### 可以做（已实测可用）

| 能力 | 说明 |
| --- | --- |
| 读矿机状态 | `/proc`、`nvidia-smi`、`df`、`sensors` 等 |
| 读/写文件 | 自己的状态目录、矿工日志，甚至 `/etc/hosts`（root） |
| 观察进程与网络 | `ps`、`pgrep`、`ss -tnp`、`lsof`、`/proc/net/tcp` |
| 网络控制 | Linux `iptables` / `iptables-legacy` / `nft`（需 root），Windows `netsh advfirewall` |
| 本地服务 | 监听端口做本地代理、API、看板 |
| 调用 miner 的本地 API | 多数 miner 都有（见第 9 节实测表） |
| 控制矿工 | 通过 `/home/rmos/run/rmos-agent.sock` 发 `restart`/`stop`/`start`（与服务器命令同路径） |
| 上报状态 | 进程存活状态由客户端自动上报；数据/统计要自己输出（第 8.7 节） |

### 不能做（不要设计这类方案）

| 限制 | 原因 |
| --- | --- |
| 不能改飞行表 / 矿池 / 钱包 | 飞行表由服务器下发，插件只能读 `RMOS_FLIGHT_*` 与 `plugin-config.json` |
| 不能给控制台加界面/按钮 | 插件没有 UI 扩展点 |
| 不能把统计数字直接推到控制台 | **目前心跳里没有插件数据通道**（只有状态）；见第 11 节 |
| 不能改写别的插件/矿工的进程内存 | 没有该能力，也不建议 |
| Windows 上不能做"默认拒绝"式放行规则 | Windows 防火墙 block 规则优先于 allow，只能按目标/程序做具体规则 |

---

## 8. 实用配方（Recipes，均已在本项目矿机上验证）

### 8.1 精确统计"我们的份额"：优先读 miner 本地 API

很多 miner 自带本地 HTTP API（比抓日志可靠得多）：

```bash
curl -s http://127.0.0.1:4068/summary
```

peakminer 返回（真实样例，字段做了截断）：

```json
{"version":"2.16.0","algo":"pearl","uptime":134082,
 "pool":{"url":"prl-hk.kryptex.network:7048","ping_ms":81,"difficulty":9007199254740992.0,"connected":true},
 "dev_fee_percent":2.0,"hashrate":326039059534841.7,
 "accepted_shares":4725,"invalid_shares":0,"efficiency_pct":100.0,
 "last_share_at":1789311721,"eta_share_secs":27.66,
 "gpus":[{"id":0,"name":"RTX 3060 Ti","pci_bus_id":"01:00.0","hashrate":49422824966302.4,
          "accepted_shares":743,"invalid_shares":0,"temperature_c":74,"fan_pct":69,"power_w":124}, ...]}
```

要点：`accepted_shares`（整机与每卡）、`difficulty`、`dev_fee_percent`、`hashrate` 一般够用。

### 8.2 退而求其次：解析矿工日志的份额行

```bash
# HiveOS 自定义包：日志在包目录里，同时被镜像到 /home/rmos/logs/miner.log
grep -c 'accepted' /hive/miners/custom/peakminer/peakminer.log
tail -5 /hive/miners/custom/peakminer/peakminer.log
```

peakminer 的真实行样例（**每笔都带难度**，可直接算折算算力）：

```
2026-09-13 14:59:41 accepted   GPU 4  lat 290ms  diff 9.01 PH  effort 169%
2026-09-13 14:59:47 accepted   GPU 0  lat 318ms  diff 9.01 PH  effort 19%
```

Python 通用正则（可覆盖多种 miner 的写法）：

```python
import re
SHARE_RE = re.compile(r"\b(accepted|rejected)\b.*?diff(?:iculty)?\s*([0-9.]+)\s*([KMGTEP]?)", re.I)
for line in open("/hive/miners/custom/peakminer/peakminer.log", encoding="utf-8", errors="replace"):
    m = SHARE_RE.search(line)
    if m:
        print(m.group(1), float(m.group(2)), m.group(3))
```

### 8.3 观察"矿工连了谁"（按 PID 归属，最通用）

```bash
MP=$(pgrep -x peakminer | head -1)          # 矿工进程 PID（agent 也是它启动的）
sudo -n ss -tnp 2>/dev/null | grep "pid=$MP,"
# 输出里 $4 = 本机地址:端口，$5 = 远端地址:端口
```

采样几次并聚合，就能得到"飞行表矿池之外的连接有哪些、各出现多少次"：

```bash
sudo -n ss -tnp 2>/dev/null | grep "pid=$MP," | awk '{print $5}' | sort | uniq -c | sort -rn
```

采样间隔建议 2~10 秒：够密才能抓到短连接，又几乎不耗资源（一次 `ss` 是毫秒级）。

### 8.4 用 iptables 计数（只统计不拦截，HiveOS 必读）

HiveOS 的 `iptables` 是 nf_tables 兼容层，**创建自定义链常常失败**；用 `iptables-legacy`。规则只写 `ACCEPT`（系统策略本来就是 ACCEPT，所以**行为完全不变**），靠计数器拿字节/包数：

```bash
IPT=/usr/sbin/iptables-legacy
sudo -n $IPT -N RMOS_COUNT
sudo -n $IPT -A RMOS_COUNT -m owner --uid-owner 0 -p tcp --dport 7048  -j ACCEPT -m comment --comment pool
sudo -n $IPT -A RMOS_COUNT -m owner --uid-owner 0 -p tcp --dport 19809 -j ACCEPT -m comment --comment server
sudo -n $IPT -A RMOS_COUNT -m owner --uid-owner 0 -p tcp                -j ACCEPT -m comment --comment other
sudo -n $IPT -I OUTPUT 1 -j RMOS_COUNT
sudo -n $IPT -L RMOS_COUNT -v -n -x          # 读计数器
# 退出前务必清理：
sudo -n $IPT -D OUTPUT -j RMOS_COUNT; sudo -n $IPT -F RMOS_COUNT; sudo -n $IPT -X RMOS_COUNT
```

**实测（D3060ti / peakminer，20 秒窗口）**：

```
2 pkts   6635 bytes  owner UID match 0 tcp dpt:7048   /* pool   */
6 pkts   6893 bytes  owner UID match 0 tcp dpt:19809  /* server */
11 pkts  3677 bytes  owner UID match 0                 /* other  */
```

`other` 桶里会混入 DNS/NTP/agent 其它流量，**要按目标端口/地址再细分**才能当"抽水流量"用（见第 9 节）。

### 8.5 透明观察器（看协议内容，才能数清"抽水份额"）

想让矿工的挖矿流量经过你（从而看见 stratum 内容：登录名、难度、每笔提交），有两个办法：

1. **让平台把飞行表矿池指向本机**：把矿池地址写成 `127.0.0.1:8899`，插件监听 8899 再转发到真矿池 —— 这是最干净的做法（但需要改飞行表，属于用户可见的操作）。
2. **用 iptables 重定向**（不改飞行表）：

```bash
# 自己的上游连接先打 mark 放行，避免自环（插件里用 setsockopt(SO_MARK, 0x5fb1)）
sudo -n $IPT -t nat -I OUTPUT 1 -m mark --mark 0x5fb1 -j RETURN
sudo -n $IPT -t nat -A OUTPUT -p tcp --dport 7048 -j REDIRECT --to-ports 8899
```

Python 里的自环保护：

```python
sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, 36, 0x5FB1)   # SO_MARK，仅 root 可用
sock.connect(("prl-hk.kryptex.network", 7048))
```

> ⚠️ **实测教训（务必照做）**：透明观察器**必须以 root 运行**（SO_MARK 需要权限），而且**在观察器确认监听成功之前不要装重定向**。
> 我第一版用普通用户跑观察器，上游拨号被拒 → 矿工 `authorize failed` → **掉线约 5 分钟**。
> 正确顺序：启动观察器 → 探测端口可连 → 再装重定向 → 退出/崩溃时用 `trap` 立刻撤规则。

### 8.6 触发矿工重连（观察器要看到新连接时）

NAT 重定向只对新连接生效；矿工的长连接不会自己断开。用 agent 自带的控制 socket 让它重连（与服务器下发的 `restart_miner` 同一套代码）：

```bash
python3 - <<'PY'
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(120)
s.connect('/home/rmos/run/rmos-agent.sock')
s.sendall(b'restart')          # start / stop / restart / status
print(s.recv(4096).decode().strip())
PY
```

### 8.7 插件怎么把结果给用户看（当前可用的三种）

| 方式 | 做法 | 用户在哪里看到 |
| --- | --- | --- |
| agent 日志 | `print(...)` | SSH 里 `tail -f /home/rmos/logs/agent.log`，前缀 `plugin/<名称>` |
| 矿工控制台日志 | 追加一行到 `/home/rmos/logs/miner.log`（即 `miner` 命令的屏幕） | SSH 里 `miner` 或 `tail -f /home/rmos/logs/miner.log` |
| 状态文件 | 写 `$RMOS_STATE_DIR/plugin-stats/<名称>.json` | 你自己/后续版本读取（控制台暂无展示位，见第 11 节） |

推荐格式（便于以后接入控制台）：

```json
{
  "plugin": "my-stats",
  "updated_at": "2026-09-13T15:00:00Z",
  "window_seconds": 3600,
  "our_shares": { "source": "miner_api", "our_shares": 120, "difficulty": 9007199254740992, "declared_dev_fee_percent": 2.0 },
  "non_flight_peers": [ { "remote": "1.2.3.4:443", "samples": 12, "seconds_estimate": 360 } ]
}
```

---

## 9. 专项案例：抽水（dev fee）统计插件

这一节是"用文档 + AI 做出专用抽水统计插件"的核心材料，结论来自**在真实矿机（D3060ti / Peakminer 2.16.0 / Kryptex 明文 stratum）上的实测**。

### 9.1 先分清两类抽水实现（决定你能不能统计出来）

| 类型 | 表现 | 能不能统计 |
| --- | --- | --- |
| **独立连接型** | 矿工周期性另开连接（不同端口/域名）去抽水矿池，例如已知的 SRBminer 抽水端口 `3360`/`8111` | **能**：`ss` 采样 + iptables 计数拿到时间/字节；用端口重定向还能把份额数清楚 |
| **同连接型** | 抽水复用同一条矿池连接，用**另一个登录名/份额标签**提交（Miner 只在日志里写 `dev_fee=2.0%`） | 连接层统计**看不见**（实测：37 小时日志只有一条 socket、一个钱包）；只有**透明观察器读 stratum 内容**才能数清 |

### 9.2 实测数据（peakminer）

* 启动行：`INFO peakminer/2.16.0 — coin=pearl wallet=prl1…3862.D3060ti legacy_auth=false dev_fee=2.0%`
* 本地 API：`dev_fee_percent=2.0`、`accepted_shares=4725`、`difficulty=9.007e15`
* 日志份额行与 API 计数**逐条一致**（4727 → 4728 → 4729），说明 `accepted_shares` 就是"这次会话总计提交/被接受的份额"
* 5 分钟、每 2 秒一次的按 PID 采样：**始终只有 1 条连接**（飞行表矿池）
* 37 小时完整日志：**只有 1 个矿池地址、1 个钱包**，无抽水切换痕迹
* ⇒ peakminer 属于**同连接型**；"非飞行表连接时间/字节"推算对它会得到 0，**不能作为它的抽水统计口径**

### 9.3 各类 miner 的数据源实测表（同一机群抽样）

| Miner（机群在线数） | 本地 API | 份额日志 | 抽水可见性 | 建议口径 |
| --- | --- | --- | --- | --- |
| `peakminer`（13） | ✅ `127.0.0.1:4068/summary`（份额/难度/声明抽水%） | ✅ 每笔带 `diff` | 同连接型 | API 精确份额 + 声明 % + （可选）观察器实测 |
| `lolMiner`（6） | ✅ 有 API（`--apiport`） | ✅ | 待实测 | 同 peakminer |
| `srbminer_custom`（1） | ✅ 有 API | ✅ | **独立连接型**（已知 3360/8111） | 端口重定向观察 + 连接计数 |
| `golden_miner_hiveos`（11） | ❌ 无 | ❌ 无份额行（HTTPS 443 prover） | 未知 | 只能给"连接画像 + 声明值"标注 |
| `quanpool-hive`（8） | 待确认 | 待确认 | 未知 | 先做通用日志正则 + 连接画像 |

> 结论：**"对所有 miner 通用"的正确形态是"分层口径 + 标注来源"**：
> `实测（API）` > `实测（协议观察）` > `推算（连接时间/字节）` > `声明值（miner 自报 dev_fee%）`。
> 界面上必须标清每个数字是哪一类，否则会误导用户。

### 9.4 统计口径写法（推荐给 AI 的规格）

```
窗口：用户点“启动”到“停止”之间（或最近 N 分钟滑动窗口）
输出：
  1) 我们的份额：accepted / rejected / 难度加权折算算力，来源=miner_api|miner_log
  2) 抽水侧：
       - 若观察器可用（能看到 stratum）：按登录名分组的提交数 = 精确抽水份额，来源=protocol
       - 否则若发现独立连接：按连接时长/字节占比 × 我们的份额 = 推算抽水份额，来源=estimated
       - 否则：显示 miner 声明的 dev_fee%（来源=declared），并明确“未实测”
  3) 对照：声明值 vs 实测/推算值，以及窗口内“被抽走的算力估算”= 本地算力 × 抽水占比
  4) 连接画像：非飞行表目标列表（remote:port、出现次数、估算时长、可选字节数）
  5) 全程只读：不阻断、不改写、不限速；退出时清理自己加的 iptables 规则
```

---

## 10. 用 AI 写插件：提示词模板

把**本文档**和下面这段一起交给 AI（Claude / GPT / DeepSeek 等均可）：

```
你是 RMOS 插件开发者。请严格按我附上的《RMOS 插件开发文档（Plugin API v1）》实现一个插件。

目标：<用一句话说清要做什么，例如“统计每个时间窗内属于我们钱包的份额，以及非飞行表连接的时长/字节，输出成 plugin-stats JSON 并在 agent 日志里打印摘要”>

平台与语言：<Linux(Go) | Linux(Python) | Windows(PowerShell) | 跨平台>
矿机环境：HiveOS + RMOS agent（root 权限），矿工是 <peakminer 2.16.0 / lolMiner / ...>，矿池是 <host:port，是否 TLS>

硬性要求：
1) 只读优先：不阻断、不改写矿工流量；确需看清协议时，用“透明转发 + 只计数”的方式，并给出安全开关；
2) 任何改动系统网络的行为（iptables/hosts/防火墙）必须有：就绪探测、失败自动回滚、退出/崩溃 trap 清理、dry-run 模式；
3) 长时间运行、内部重试、不要把异常抛出去导致进程退出（退出会让控制台显示 stopped）；
4) 输出：plugin-stats/<名称>.json（按文档 8.7 的格式）+ stdout 摘要行（会进 agent 日志）+ 可选往 /home/rmos/logs/miner.log 追加一行；
5) 参数全部通过 RMOS_PLUGIN_PARAM_* 读取，并在 plugin.json/参数表里给出默认值；
6) 交付：完整目录结构、plugin.json、全部源码、打包与 SHA-256 命令、以及“怎么在单台矿机上灰度验证”的步骤。

请先给出实现方案（数据来源、统计口径、失败与回滚策略），我确认后再写代码。
```

> 提示 AI 的关键点：**先让它说清"数据从哪来、边界在哪"，再让它写代码**；
> 并要求它区分"实测/推算/声明"三种来源 —— 这是这套插件最容易出错、也最容易误导人的地方。

---

## 11. 尚未实现的能力（设计时别依赖，需要可提需求）

| 缺失 | 影响 | 现状下的替代做法 |
| --- | --- | --- |
| 插件**数据回传通道** | 统计数字无法直接显示在控制台 | 写 `plugin-stats/*.json` + stdout 摘要（第 8.7 节），用户在 SSH 里看 |
| 插件**启用/停用**状态 | 没有独立的启停按钮 | 用"应用/移除"当启动/停止；用"改参数"当重启 |
| 控制台**插件面板** | 看不到插件的自定义指标 | 同上 |
| 插件**崩溃自动重启**（带退避） | 插件退出后保持 stopped | 插件内部自愈循环；或用户重新应用 |

> 这些是插件生态的自然演进方向；如果你在做插件时确实需要，把需求整理出来，平台侧可以按"小改动"补上（数据通道大致只需要：约定 `plugin-stats/*.json` → agent 心跳携带 → 服务端存储 → 控制台展示）。

---

## 12. 安全与合规（务必阅读）

1. **插件以 root/SYSTEM 运行**，来源必须可信；平台侧只允许管理员发布插件，发布前应审阅包内容。
2. **始终提供 SHA-256**；不要用不可信域名做下载地址。
3. **不要让插件变成故障点**：任何串在挖矿链路里（代理/重定向/改写）的实现，都必须有就绪探测 + 崩溃自动撤规则 + dry-run；本文档 8.5 节的实测事故就是反面教材。
4. **不要硬编码密钥**；需要配置就读参数或 `$RMOS_STATE_DIR` 下自己的文件。
5. **抽水相关的边界**：
   * 统计（只观察、不改写）没有任何副作用，推荐作为默认形态；
   * **阻断或改写 Miner 的 dev fee 属于你作为设备所有者/运营者的决策**：这会让 Miner 作者拿不到其声明的收益，可能违反该软件的许可条款（例如 peakminer 的启动横幅明确写了 proprietary / 禁止逆向）；
   * 如果矿机不是你自己的（客户矿机），**必须事先获得授权并写进条款**，尤其是把抽水改写到你自己地址的场景；
   * 平台侧的既有示例插件只对*特定* Miner 的抽水端口做处理，请勿把这类行为默认应用到不属于你的设备。
6. 上线前在**单台测试矿机**验证：应用 → 看状态 → 看日志 → 停止/移除 → 确认 iptables/hosts 等系统改动已被清理。

---

## 13. 调试与上线流程

```
1) 本地/单台开发：把插件包放到你的 HTTPS 或平台 /dl/
2) 平台管理 → 插件管理：填包信息（版本号先给 0.0.1），保存
3) 矿机详情 → 插件：应用（填参数）
4) 观察：
   tail -f /home/rmos/logs/agent.log      # 插件 stdout/状态
   tail -f /home/rmos/logs/miner.log      # 你追加给用户看的摘要行
   cat /home/rmos/plugin-stats/<名称>.json
   sudo ss -tnp | grep <矿工进程>          # 确认你的监听/连接
5) 改代码后必须**升版本号**重新发布（同版本不会被重新下载），再重新应用
   —— 追求快速迭代时，也可以在矿机上手工替换 /home/rmos/plugins/<名称>/<版本>/ 下的文件并重新应用（仅测试机）
6) 移除插件，检查系统是否干净：iptables -S / iptables-legacy -t nat -S / cat /etc/hosts
7) 单台稳定运行 24 小时后再批量应用（控制台批量操作 -> 应用插件）
```

---

## 14. 参考实现与文件位置

* 平台自带示例（源码在项目 `tools/plugins/`）：`srbminer-fee-intercept` —— 用 `iptables -t nat REDIRECT` 把 SRBminer 的抽水端口引到本地代理，尝试 MITM 失败后改为**阻断并计数**，并向矿工控制台打印拦截次数。它演示了：SO_MARK 防自环、`iptables-legacy` 兼容、控制台反馈、参数读取。
* 包目录约定：`release/plugins/<插件名>/<版本>/`（不含 GitHub 发布，见 `release/plugins/README.md`）。
* 状态文件：`$RMOS_STATE_DIR/plugins.json`（客户端维护的插件清单，插件不要改它）。

### 附录 A：速查表

| 需要什么 | 用什么 |
| --- | --- |
| 当前矿池/币种/算法/钱包/矿工 | `RMOS_FLIGHT_*`、`RMOS_WALLET`、`RMOS_FLIGHT_MINER`、`plugin-config.json` |
| 用户填的参数 | `RMOS_PLUGIN_PARAM_<KEY>`（键名大写、非字母数字转 `_`） |
| 自己的状态文件 | `$RMOS_STATE_DIR/...` |
| 矿工进程 PID | `pgrep -x <RMOS_FLIGHT_MINER>`（HiveOS 上包名可能与可执行名略有差异，用 `ps` 确认） |
| 矿工日志 | `/hive/miners/custom/<包>/*.log`、`/home/rmos/logs/miner.log` |
| 矿工本地 API | 见第 9.3 节表格；无 API 时抓日志 |
| 控制矿工 | `/home/rmos/run/rmos-agent.sock` → `start` / `stop` / `restart` / `status` |
| 只统计流量 | `iptables-legacy` ACCEPT 计数链（第 8.4 节） |
| 看协议内容 | 透明转发观察器 + `SO_MARK`（第 8.5 节，root + 就绪探测 + trap 清理） |

### 附录 B：状态与错误码

| 状态 | 触发 |
| --- | --- |
| `starting` | 服务器刚下发 `set_plugins` |
| `running` | 进程已启动 |
| `stopped` | 进程退出；`error_code` = 退出码（0 正常） |
| `error` | `error_code=install`（下载/校验/解压/找不到入口）或 `start`（启动失败）；`detail` 为原因 |

### 附录 C：打包命令示例（Linux 插件）

```bash
mkdir -p my-plugin/bin
# 放入 plugin.json 与可执行文件
chmod +x my-plugin/bin/my-plugin
tar -czf my-plugin-1.0.0.tar.gz -C my-plugin .
sha256sum my-plugin-1.0.0.tar.gz          # 把这一行的哈希填到插件管理的 SHA-256
```

Windows 插件（PowerShell）用 `Compress-Archive -Path my-plugin\* -DestinationPath my-plugin-1.0.0.zip`，
入口写 `.ps1`（客户端会用 `powershell -NoProfile -ExecutionPolicy Bypass -File` 启动）。

### 附录 D：服务端命令（内部协议，集成/排查参考）

| 命令 | 载荷 | 说明 |
| --- | --- | --- |
| `set_plugins` | `{"plugins":[PluginDef...]}` | **全量对齐**：不在列表中的插件被停止，列表中的下载并启动 |
| `restart_miner` | `{"flight_sheet":{...}}` | 停止后按飞行表重新启动 Miner |
| `stop_mining` | `{}` | 仅暂停 Miner，飞行表指派与本地状态保留 |
| `clear_flight_sheet` | `{}` | 停止 Miner 并清除飞行表指派与本地状态 |

网页端均通过 `POST /api/v1/master/rigs/batch-action` 下发上述命令；矿机上也可以直接对
`/home/rmos/run/rmos-agent.sock` 发 `start` / `stop` / `restart` / `status`（第 8.6 节）。


---

*文档版本：2026-09-13（对应用户服务器 0.16.1.x / agent 0.11.x）。欢迎把这份文档连同你的目标一起交给 AI 生成插件；如遇文档与实际行为不一致，以实际客户端行为为准并反馈给我们。*


---

## 附录 E：可直接改造的完整示例插件（抽水/份额统计，只统计不干预）

源码同时放在平台源码树 `tools/plugins/example-share-stats/`（含 README.md 与 plugin.json），
**完整代码也在本附录中原样给出**，直接复制即可使用（插件包按平台约定不发布到 GitHub，只放服务器下载目录）。
把这份文档连同你的需求交给 AI，让它在这个骨架上改，比从零写快得多。

**目录结构**

``
example-share-stats/
├── plugin.json
└── bin/
    └── example-stats.py
``

**plugin.json**

``json
{
  "name": "example-share-stats",
  "version": "1.0.0",
  "api": "1",
  "description": "示例：只统计不干预的抽水/份额统计（miner 本地 API 或日志 + 非飞行表连接画像）",
  "entry": "bin/example-stats.py"
}
``

**bin/example-stats.py**

``python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""示例插件：抽水/份额统计（只统计、不拦截、不改写任何流量）。

它演示了 RMOS 插件文档里的三条核心配方：
  1) 从 miner 的本地 API / 日志里取“属于我们的份额”（精确）；
  2) 从 miner 进程的 TCP 连接里取“非飞行表连接”的时间与字节（推算独立连接型抽水）；
  3) 把结果写进 RMOS_STATE_DIR 下的 JSON 并周期性打到 stdout（会进 agent 日志）。

环境变量由 RMOS 客户端注入，见 docs/PLUGIN_API.md 第 4 节。
"""
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.request

POLL_SECONDS = int(os.environ.get("RMOS_PLUGIN_PARAM_POLL_SECONDS", "30"))
WINDOW_SECONDS = int(os.environ.get("RMOS_PLUGIN_PARAM_WINDOW_SECONDS", "3600"))
MINER_API = os.environ.get("RMOS_PLUGIN_PARAM_MINER_API", "http://127.0.0.1:4068/summary")
# 通用日志解析：把“accepted … diff <数值><单位>”这类行统计出来
SHARE_RE = re.compile(r"\b(accepted|rejected)\b.*?diff(?:iculty)?\s*([0-9.]+)\s*([KMGTEP]?)", re.I)
STATE_DIR = os.environ.get("RMOS_STATE_DIR", "/home/rmos")
PLUGIN_NAME = os.environ.get("RMOS_PLUGIN_NAME", "example-stats")
OUT_DIR = os.path.join(STATE_DIR, "plugin-stats")
LOG_HINT = os.environ.get("RMOS_PLUGIN_PARAM_MINER_LOG", "")


def log(message):
    """stdout 会被客户端加上 plugin/<名称> 前缀转进 agent 日志。"""
    print("[%s] %s" % (PLUGIN_NAME, message), flush=True)


def read_miner_api():
    """读 miner 自己的本地 API（有则最准）。返回 dict 或 None。"""
    try:
        with urllib.request.urlopen(MINER_API, timeout=4) as resp:
            return json.loads(resp.read().decode("utf-8", "replace"))
    except Exception:
        return None


def read_log_shares():
    """没有本地 API 时退化为解析 miner 日志的份额行。"""
    if not LOG_HINT or not os.path.exists(LOG_HINT):
        return None, None
    accepted = rejected = None
    try:
        with open(LOG_HINT, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = SHARE_RE.search(line)
                if not match:
                    continue
                count = 1
                if match.group(1).lower() == "accepted":
                    accepted = (accepted or 0) + count
                else:
                    rejected = (rejected or 0) + count
    except Exception as exc:
        log("read log failed: %s" % exc)
        return None, None
    return accepted, rejected


def miner_pid():
    try:
        out = subprocess.check_output(["pgrep", "-x", os.environ.get("RMOS_FLIGHT_MINER", "miner")],
                                     stderr=subprocess.DEVNULL, timeout=5)
        pids = [line.strip() for line in out.decode().split() if line.strip()]
        return pids[0] if pids else None
    except Exception:
        return None


def sample_peers(pid, allow):
    """按 PID 采样 miner 的远端连接，区分“飞行表矿池”与“其它”。"""
    others = {}
    if not pid:
        return others
    try:
        out = subprocess.check_output(["ss", "-tnp"], stderr=subprocess.DEVNULL, timeout=5).decode()
    except Exception:
        return others
    needle = "pid=%s," % pid
    for line in out.splitlines():
        if needle not in line:
            continue
        parts = line.split()
        if len(parts) < 5:
            continue
        remote = parts[4]
        host = remote.rsplit(":", 1)[0]
        if any(token and token in remote for token in allow):
            continue
        others[remote] = others.get(remote, 0) + 1
    return others


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    pool = os.environ.get("RMOS_FLIGHT_POOL", "")
    wallet = os.environ.get("RMOS_WALLET", "")
    log("started worker=%s miner=%s pool=%s window=%ds poll=%ds" % (
        os.environ.get("RMOS_WORKER", "-"), os.environ.get("RMOS_FLIGHT_MINER", "-"), pool or "-",
        WINDOW_SECONDS, POLL_SECONDS))

    started = time.time()
    peers = {}
    last_api = None
    while True:
        time.sleep(POLL_SECONDS)
        api = read_miner_api()
        if api:
            last_api = {
                "source": "miner_api",
                "our_shares": api.get("accepted_shares"),
                "invalid_shares": api.get("invalid_shares"),
                "difficulty": (api.get("pool") or {}).get("difficulty"),
                "declared_dev_fee_percent": api.get("dev_fee_percent"),
                "hashrate": api.get("hashrate"),
                "elapsed": int(time.time() - started),
            }
        else:
            accepted, rejected = read_log_shares()
            last_api = {"source": "miner_log" if accepted is not None else "unavailable",
                        "our_shares": accepted, "invalid_shares": rejected,
                        "elapsed": int(time.time() - started)}

        pid = miner_pid()
        for remote, count in sample_peers(pid, [pool]).items():
            entry = peers.setdefault(remote, {"samples": 0, "first": time.time()})
            entry["samples"] += count
            entry["last"] = time.time()

        snapshot = {
            "plugin": PLUGIN_NAME,
            "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "window_seconds": WINDOW_SECONDS,
            "elapsed_seconds": int(time.time() - started),
            "flight": {"pool": pool, "wallet": wallet, "coin": os.environ.get("RMOS_FLIGHT_COIN", ""),
                       "miner": os.environ.get("RMOS_FLIGHT_MINER", "")},
            "our_shares": last_api,
            "non_flight_peers": [{"remote": remote, "samples": data["samples"],
                                  "seconds_estimate": data["samples"] * POLL_SECONDS}
                                 for remote, data in sorted(peers.items(),
                                                            key=lambda kv: -kv[1]["samples"])],
        }
        path = os.path.join(OUT_DIR, PLUGIN_NAME + ".json")
        try:
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(snapshot, handle, ensure_ascii=False, indent=2)
        except Exception as exc:
            log("write stats failed: %s" % exc)
        log("our_shares=%s source=%s non_flight_peers=%d (stats: %s)" % (
            (last_api or {}).get("our_shares"), (last_api or {}).get("source"),
            len(snapshot["non_flight_peers"]), path))

        if time.time() - started >= WINDOW_SECONDS:
            log("window finished after %ds" % WINDOW_SECONDS)
            started = time.time()
            peers = {}


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
``

**打包**

``bash
cd example-share-stats
tar -czf example-share-stats-1.0.0.tar.gz -C . .
sha256sum example-share-stats-1.0.0.tar.gz
``

**它演示了什么**

| 能力 | 对应文档章节 |
| --- | --- |
| 读 miner 本地 API 取"我们的份额/难度/声明抽水%" | 8.1 / 9.3 |
| 无 API 时退回日志正则解析 | 8.2 |
| 按 PID 采样连接、区分飞行表矿池与其它远端 | 8.3 |
| 结果写 plugin-stats/*.json + stdout 摘要 | 8.7 |
| 参数全部走 RMOS_PLUGIN_PARAM_* | 5.2 |

> 注意：这个示例**故意不碰系统网络**（不加 iptables、不改 hosts、不做重定向），
> 所以它对"同连接型抽水"只能给出 miner 声明的比例；要实测同连接型抽水，按 8.5 节加观察器，
> 并严格遵守那里的就绪探测与自动回滚要求。
