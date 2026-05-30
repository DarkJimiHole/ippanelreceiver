# IPPanelReceiver

IPPanelReceiver 用于接收 `ippanelbot` 上报的 IP 变更请求，并调用本机
easynftables 的 `nf` 命令更新转发目标。

它适合安装在已经使用 easynftables 的中转 VPS 上。
关于 easynftables，详见 [DarkJimiHole/easynftables](https://github.com/DarkJimiHole/easynftables)。

## 安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/DarkJimiHole/ippanelreceiver/main/ippanelreceiver.sh)
```

安装脚本会创建：

- 服务：`ippanelreceiver.service`
- 命令：`ippanelreceiver`
- 程序目录：`/opt/ippanelreceiver`
- 配置文件：`/etc/ippanelreceiver/config.json`

## 配置

示例：

```json
{
  "listen": {
    "host": "10.77.0.2",
    "port": 8787,
    "path": "/report"
  },
  "nf_command": "/usr/local/sbin/nf",
  "reporters": {
    "bot-main": {
      "allowed_ips": ["10.77.0.1"],
      "secret": "replace-with-a-long-random-secret"
    }
  },
  "receivers": {
    "receiver1": {
      "allowed_reporters": ["bot-main"],
      "match_modes": ["remark", "old_ip", "old_ip_unique"],
      "remark": "receiver1"
    }
  }
}
```

`reporter` 表示一个被允许上报的 `ippanelbot` 实例。

`receiver_name` 表示 receiver 端的一个更新目标。使用 `remark` 模式时，
`remark` 应该和 easynftables 里的备注一致。

## 上报内容

```json
{
  "reporter": "bot-main",
  "receiver_name": "receiver1",
  "match_mode": "remark",
  "ip": "new.ip.address.here",
  "old_ip": "old.ip.address.here",
  "ts": 1770000000,
  "nonce": "random-string"
}
```

签名请求头：

```text
X-IPPanelReceiver-Signature: sha256=<hmac_sha256(secret, raw_body)>
```

支持的 `match_mode`：

- `remark`：调用 `nf --set-dest-ip-by-remark <remark> <ip>`
- `old_ip`：调用 `nf --set-dest-ip-by-current-ip <old_ip> <ip>`
- `old_ip_unique`：调用 `nf --set-dest-ip-by-current-ip-unique <old_ip> <ip>`

## 命令

```bash
sudo ippanelreceiver install
sudo ippanelreceiver configure
sudo ippanelreceiver check
sudo ippanelreceiver start
sudo ippanelreceiver stop
sudo ippanelreceiver restart
sudo ippanelreceiver status
sudo ippanelreceiver logs
sudo ippanelreceiver uninstall
```

## 注意

建议在 `ippanelbot` 和每台 receiver VPS 之间使用 WireGuard 组网。
receiver 可以在这个私有网络里使用普通 HTTP，而传输层由 WireGuard 加密。

如果运行 `ippanelbot` 或 `ippanelreceiver` 的服务器本身也是动态
公网 IP，可以使用稳定中继节点、DDNS 或 `PersistentKeepalive` 来维持私有网络可用。

不要把 receiver 端口暴露到公网。建议每个 reporter 使用独立密钥，
`allowed_ips` 尽量收窄，除非你确实要转发到私有地址，否则保持
`allow_private_target_ips` 关闭。
