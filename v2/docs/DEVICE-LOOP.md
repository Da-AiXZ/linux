# 设备回传链路（安装 → 自动跑 → 自动上传 → 唤醒）

目标：iPad 装上包，打开就跑预设测试，日志自动回到工作站，我这边被唤醒。
不需要你复制日志、不需要截图、不需要说"跑完了"。

## 角色

| 角色 | 在哪 | 做什么 |
|---|---|---|
| `Tools/v2_log_server.py` | 工作站 | 收日志、发命令、UDP 应答发现 |
| App 里的 `V2Remote` | iPad | 启动即跑 → POST 日志 → 长轮询命令 |
| `Tools/v2_wait.py` | 工作站（后台） | 等到新日志就退出，退出即唤醒我 |

## 协议

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/v2/ping` | `{"ok":1,"port":8765}`，用于确认地址可达 |
| POST | `/v2/upload?device=&build=&run=` | body 是纯文本日志；返回 `{"ok":1,"id":"…"}` |
| GET | `/v2/command?wait=25` | 长轮询；返回 `{"action":"run","args":["ls"]}` 或 `{"action":null}` |
| POST | `/v2/ack` | 设备回报执行结果，追加到 `acks.txt` |

发现：向 UDP 8766 发 `V2DISCOVER`，服务器回 `V2LOG <port> <ip1,ip2,…>`。
工作站常有多个网卡（Wi-Fi、WSL、Hyper-V、VPN），所以回**全部**地址，
设备逐个试——不猜"包是从哪块网卡进来的"。

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

首次运行 Windows 会弹防火墙；也可以提前放行（管理员 PowerShell）：

```powershell
netsh advfirewall firewall add rule name="v2 log tcp" dir=in action=allow protocol=TCP localport=8765
netsh advfirewall firewall add rule name="v2 log udp" dir=in action=allow protocol=UDP localport=8766
```

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

## App 侧还差什么

`V2Remote.m`（上传 + 发现 + 长轮询 + 断线重试）要等 v2 的 App target 落地才编进去。
它不做任何判断，只负责"启动跑什么、跑完发什么"，测试逻辑在 `v2/tests/guest/`。

App 的启动顺序约定（写进代码，不靠记忆）：

1. 读 `UserDefaults` 里的 `uploadURL`；没有就 UDP 发现（3 秒超时）
2. 立即执行默认动作（`--action` 参数或上次的动作）
3. 日志先落盘 `Documents/v2/logs/`，再上传；失败重试 3 次，间隔 2/5/10 秒
4. 上传成功后长轮询 25 秒等命令，拿到就执行、回报、继续轮询
5. 屏幕常亮、切后台不退出（TrollStore 环境下可用 `no-sandbox`）

## 为什么不用云

- 局域网直连，没有第三方、没有账号、没有额外交互；
- 日志一行不落地经过别人的服务器；
- 断网时 App 仍然把日志写本地，下次联网补传。
