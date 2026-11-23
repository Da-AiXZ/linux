# 设备回传链路（安装 → 自动跑 → 自动上传 → 唤醒）

目标：iPad 装上包，打开就跑预设测试，日志自动回到工作站，我这边被唤醒。
不需要你复制日志、不需要截图、不需要说"跑完了"。

## 角色

| 角色 | 在哪 | 做什么 |
|---|---|---|
| `Tools/v2_log_server.py` | 工作站 | 收日志、发命令、UDP 应答发现、每 2 秒广播 beacon |
| `Tools/v2_open_firewall.ps1` | 工作站（一次性） | 放行 8765/tcp、8766+8767/udp（需要管理员） |
| App 里的 `V2Remote` | iPad | 启动即跑 → POST 日志 → 长轮询命令 |
| `Tools/v2_wait.py` | 工作站（后台） | 等到新日志就退出，退出即唤醒我 |

## 协议

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/v2/ping` | `{"ok":1,"port":8765}`，用于确认地址可达 |
| POST | `/v2/upload?device=&build=&run=` | body 是纯文本日志；返回 `{"ok":1,"id":"…"}` |
| GET | `/v2/command?wait=25` | 长轮询；返回 `{"action":"run","args":["ls"]}` 或 `{"action":null}` |
| POST | `/v2/ack` | 设备回报执行结果，追加到 `acks.txt` |

发现是**双向**的，两条路任意一条通就够：

1. **主动**：设备向 UDP 8766 发 `V2DISCOVER`（受限广播 + 每块网卡的有向广播 + 回环），
   服务器回 `V2LOG <port> <ip1,ip2,…>`。工作站常有多个网卡（Wi-Fi、WSL、Hyper-V、VPN），
   所以回**全部**地址，设备**并发** ping 它们——WSL 的 172.31.x 不会拒绝连接，只会
   一直等到超时，串行试就要多等几秒。
2. **被动**：服务器每 2 秒向 UDP 8767 广播一次 `V2LOG <port> <地址们>`。设备只听不说，
   适合接入点把设备的广播丢掉、但服务器的广播能送达的情况。

无论哪条路，候选地址都并发 ping 一次，**序号最靠前的可达地址胜出**并记住。

## 诊断（0.1.2 起）

失败不再只说 `failed`，会说清是哪一步：

```
[app] server=http://192.168.144.180:8765
[app] upload failed (http://172.31.160.1:8765 -> NSURLErrorDomain -1004)
[app] upload failed (no beacon and no discovery reply -- local network
                     permission on the device, or a firewall on the workstation)
```

服务器侧会打印 `ping from <ip>`——设备第一次连上来时出现这一行，它就是链路真通了的证据。

状态都在 `.remote/v2/`（已在 `.gitignore` 里）：

```
logs/<时间>-<run>-<build>.log
inbox.txt      一行一次上传：id|字节|设备|构建
commands.txt   命令队列，一行一条；GET 取走即删
acks.txt       设备回执
```

## 启动

```bash
# 正常模式（一直开着，适合连续调试）
python Tools/v2_log_server.py

# 单次模式：收到一次上传就退出——配合后台 waiter 用来唤醒我
python Tools/v2_log_server.py --once
```

**防火墙必须先放行一次**（管理员权限；助手不能自己提权）：

右键 `Tools\v2_open_firewall.ps1` → **以管理员身份运行**。

脚本放行三个端口：

| 端口 | 协议 | 用途 |
|---|---|---|
| 8765 | TCP | 上传日志、长轮询命令 |
| 8766 | UDP | 发现应答 |
| 8767 | UDP | beacon |

这一条不是可选的：Windows 把 Wi-Fi 默认归到 **公用网络**，而公用配置**默认拒绝所有入站**。
2026-11-23 第一次真机安装就栽在这里——设备根本没连上，日志里只有 `failed`，
看起来像代码 bug，其实是网络策略。

只想本机自测、完全不碰网络：`--bind 127.0.0.1`。

## 一次完整回合长什么样

```
[21:14:38] upload 20261123-231438-loop-0.log 1354B device=fake build=0
[21:14:38] --once: upload received, stopping
```

我这边：后台 `v2_wait.py` 退出 → 任务完成通知 → 我读 `logs/…log` → 给下一条命令：

```bash
echo "run busybox ls -l /" >> .remote/v2/commands.txt
```

设备下一次轮询就会拿到它，不需要重新打包。

## 现在能测什么

工作站的整条链路已经用**假设备**跑通（发现、上传、入库、命令、回执）：

```bash
python Tools/v2_log_server.py --port 8799 --udp 8798 --once &
python Tools/v2_fake_device.py --port 8799 --udp 8798 --command "run ls -l /"
```

输出：

```
discovered port 8799, candidates ['172.31.160.1', '192.168.144.180']
using 172.31.160.1
upload -> {'ok': 1, 'id': '20261123-231521-loop-0.log'}
command-> {'action': 'run', 'args': ['ls', '-l', '/']}
```

## App 侧

已落地（`v2/app/`）：`V2Remote` 负责发现/上传/长轮询，`V2Runner` 负责 spawn 助手并
detach（拿到 `CS_DEBUGGED`），`V2ViewController` 只负责显示日志。

启动顺序：

1. 手动地址（用户在 "…" 里填过）→ 缓存地址 → 双通道发现
2. 立即跑内置 guest（`Helpers/hello`），不点任何按钮
3. 上传；失败重试 3 次，间隔 2/5/10 秒；每次失败写明地址 + 错误码
4. 成功后长轮询 25 秒等命令，拿到就执行、回报
5. 全部失败时日志留在设备上，屏幕上也能看到

右上角 "…" 菜单：**Run again / Set server address… / Copy log / Share log… / Clear log**。
手填地址写进 `UserDefaults`（键 `v2.manualBaseURL`），优先级高于发现——
换网络、换工作站不用重新打包。

## 装完怎么判定成功

```
[app] server=http://192.168.144.180:8765
[v2] patch svc=2 mrs=0 msr=0
hello from guest
[app] guest exited status=0        ← 0.1.2 起；0.1.1 这里是 killed by signal 10
[app] uploaded id=2026…-auto-0.1.2.3.log
```

服务器侧同时出现 `ping from 192.168.144.x`。

## 为什么不用云

- 局域网直连，没有第三方、没有账号、没有额外交互；
- 日志一行不落地经过别人的服务器；
- 断网时 App 仍然把日志写本地，下次联网补传。
