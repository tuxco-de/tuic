# TUIC 使用文档

本文档适用于当前仓库版本 `1.8.6`，给出从构建到运行、常用功能配置和排障的完整路径。示例使用 TOML；客户端和服务端也支持 YAML、JSON 与 JSON5。

## 1. 快速开始

### 1.1 环境要求

- Rust stable，最低 Rust 版本 `1.85.0`。
- 服务端可被客户端通过 UDP 访问。
- 生产部署需要域名和可信证书，或让客户端显式信任自签名证书。

从源码构建：

```bash
cargo build --release --package tuic-server --package tuic-client
```

生成文件位于 `target/release/tuic-server` 和 `target/release/tuic-client`；Windows 下带 `.exe` 后缀。

也可以分别安装：

```bash
cargo install --git https://github.com/Itsusinn/tuic.git tuic-server
cargo install --git https://github.com/Itsusinn/tuic.git tuic-client
```

### 1.2 生成服务端配置

```bash
tuic-server --init
```

该命令在当前目录生成 `config.toml`，其中包含随机用户和管理密钥。也可以直接使用下面的最小配置。

## 2. 最小可运行配置

### 2.1 服务端

`server.toml`：

```toml
log_level = "info"
server = "[::]:443"

[users]
"f0e12827-fe60-458c-8269-a05ccb0ff8da" = "replace-with-a-long-random-password"

[tls]
self_sign = true
hostname = "tuic.example.com"
alpn = ["h3"]
```

启动：

```bash
tuic-server -c server.toml
```

自签名模式适合测试。生产环境请参照“TLS 配置”。防火墙和云安全组需要放行 `443/udp`。

### 2.2 客户端

`client.toml`：

```toml
log_level = "info"

[relay]
server = "tuic.example.com:443"
uuid = "f0e12827-fe60-458c-8269-a05ccb0ff8da"
password = "replace-with-a-long-random-password"
udp_relay_mode = "native"
congestion_control = "bbr"
alpn = ["h3"]
startup_mode = "lazy"

# 仅用于测试自签名证书。生产环境不要使用。
skip_cert_verify = true

[local]
server = "127.0.0.1:1080"
```

启动：

```bash
tuic-client -c client.toml
```

配置应用使用 SOCKS5 代理 `127.0.0.1:1080`。测试 TCP：

```bash
curl --proxy socks5h://127.0.0.1:1080 https://example.com
```

`socks5h` 会把域名交给代理端解析，更适合验证完整链路。

## 3. 配置文件与命令行

### 3.1 客户端命令

```text
tuic-client -c <PATH>
tuic-client --config <PATH>
```

客户端必须提供配置文件。

### 3.2 服务端命令

```text
tuic-server -c <PATH>
tuic-server -d <DIR>
tuic-server --init
```

- `-c/--config`：指定配置文件。
- `-d/--dir`：按文件名排序，选择目录中第一个 `.toml`、`.json`、`.json5`、`.yaml` 或 `.yml` 文件。
- `-i/--init`：生成 `config.toml`。

### 3.3 格式识别

客户端和服务端支持 TOML、YAML、JSON/JSON5，优先级如下：

1. 存在 `TUIC_FORCE_TOML` 时强制 TOML。
2. `TUIC_CONFIG_FORMAT=toml|yaml|yml|json|json5`。
3. 文件扩展名。
4. 内容推断。

服务端还识别 `IN_DOCKER=true`，用于无标准扩展名配置的内容推断。

## 4. TLS 配置

### 4.1 使用已有证书

```toml
data_dir = "/etc/tuic"

[tls]
self_sign = false
auto_ssl = false
certificate = "cert.pem"
private_key = "key.pem"
hostname = "tuic.example.com"
alpn = ["h3"]
```

相对证书路径以 `data_dir` 为基准。服务端每 30 秒检查证书和私钥变化，可在不重启进程的情况下热加载。

客户端默认使用系统根证书，也可附加自定义 CA：

```toml
[relay]
certificates = ["/etc/tuic/ca.pem"]
disable_native_certs = false
```

### 4.2 内置 ACME

```toml
data_dir = "/var/lib/tuic"

[tls]
auto_ssl = true
self_sign = false
hostname = "tuic.example.com"
acme_email = "admin@example.com"
alpn = ["h3"]
```

ACME HTTP-01 校验要求服务端可从公网访问 TCP 80。若进程以非 root 用户运行，可通过反向代理转发挑战流量，或为二进制授予低端口绑定能力。ACME 失败时当前实现会回退到临时自签名证书，应检查日志并确认客户端证书验证没有因此失败。

### 4.3 自签名证书

```toml
[tls]
self_sign = true
hostname = "tuic.example.com"
alpn = ["h3"]
```

测试时可以在客户端设置 `skip_cert_verify=true`。更稳妥的方式是生成固定 CA/证书，并通过 `relay.certificates` 配置客户端信任。

## 5. 客户端功能

### 5.1 SOCKS5 认证

```toml
[local]
server = "127.0.0.1:1080"
username = "local-user"
password = "local-password"
dual_stack = false
max_packet_size = 1500
socks5_udp_idle_timeout = "300s"
```

用户名和密码必须同时由调用方正确提供。除非确有局域网共享需求，不要将 SOCKS5 监听到 `0.0.0.0` 或 `[::]`。

### 5.2 TCP/UDP 固定转发

```toml
[local]
# 可以省略 server，只启用固定转发。

[[local.tcp_forward]]
listen = "127.0.0.1:8080"
remote = "example.com:80"

[[local.udp_forward]]
listen = "127.0.0.1:5353"
remote = "8.8.8.8:53"
timeout = "60s"
```

可以配置多条同类规则。UDP 转发按来源地址维护会话，空闲超过 `timeout` 后释放。

### 5.3 连接策略

```toml
[relay]
startup_mode = "loop"       # eager | lazy | loop
timeout = "8s"
heartbeat = "3s"
zero_rtt_handshake = false
```

- `eager` 适合需要启动即验证链路的服务管理器。
- `lazy` 是默认值，减少未使用时的连接开销。
- `loop` 适合网络可能晚于进程就绪的设备或容器环境。

### 5.4 UDP 模式

```toml
[relay]
udp_relay_mode = "native" # native | quic
```

- `native`：使用 QUIC Datagram，延迟和语义更接近 UDP，丢包不会重传。
- `quic`：使用 QUIC 流可靠传输，适合不能容忍丢包的场景，但可能增加延迟。

### 5.5 通过 SOCKS5 访问 TUIC 服务端

```toml
[relay.proxy]
server = "127.0.0.1:1080"
username = "optional"
password = "optional"
udp_buffer_size = 2048
```

上游 SOCKS5 必须支持 UDP ASSOCIATE，因为 TUIC 的底层 QUIC 连接使用 UDP。

## 6. 服务端访问控制与出站

### 6.1 默认保护

```toml
[experimental]
drop_loopback = true
drop_private = true
```

未被显式 ACL 命中的回环和私网目标默认被阻止。建议保留默认值，并按需精确放行。

### 6.2 ACL 字符串格式

```toml
acl = """
direct *.example.com tcp/443
direct 8.8.8.8 udp/53
drop private
drop localhost
"""
```

通用格式：

```text
<outbound> <address> [<ports>] [<hijack-address>]
```

- 地址支持 IP、CIDR、域名、通配域名、`localhost` 和 `private`。
- 端口支持单端口、范围、逗号列表和 `tcp/`、`udp/` 前缀。
- 出站可为 `direct`、`default`、`drop` 或自定义出站名称。
- 规则按顺序匹配，具体规则应放在宽泛规则之前。

服务端 README 还给出了数组表格式；两种格式最终都会解析为相同 ACL 规则列表。

### 6.3 直连与命名出站

```toml
[outbound.default]
type = "direct"
ip_mode = "v4first"

[outbound.ipv6_only]
type = "direct"
ip_mode = "v6only"
bind_ipv6 = ["2001:db8::10", "2001:db8::11"]
# bind_device = "eth0"

[outbound.corporate_proxy]
type = "socks5"
addr = "127.0.0.1:1080"
username = "proxy-user"
password = "proxy-password"
allow_udp = false
```

`ip_mode` 支持 `v4first`、`v6first`、`v4only`、`v6only`。多个绑定 IP 会在匹配地址族中随机选择。

注意：服务端 SOCKS5 出站当前只完整支持 TCP。UDP 默认丢弃；`allow_udp=true` 只允许 UDP 回退直连，并不会经 SOCKS5 传输。

## 7. HTTP/3 伪装

```toml
[camouflage]
enabled = true
reverse_proxy_url = "https://127.0.0.1:8443"
reverse_proxy_hostname = "www.example.com"
request_timeout = "10s"
skip_backend_tls_verify = false
```

普通 HTTP/3 流量会被转发到后端，TUIC 流量仍进入代理协议。若 URL 主机是 IP，必须设置 `reverse_proxy_hostname`。该功能要求 TLS ALPN 包含相应的 `h3` 协议。

## 8. REST 管理接口

```toml
[restful]
addr = "127.0.0.1:8443"
secret = "replace-with-a-long-random-secret"
maximum_clients_per_user = 0
```

请求头：

```text
Authorization: Bearer replace-with-a-long-random-secret
```

常用调用：

```bash
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8443/online
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8443/detailed_online
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8443/traffic
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8443/reset_traffic
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '["f0e12827-fe60-458c-8269-a05ccb0ff8da"]' \
  http://127.0.0.1:8443/kick
```

流量统计和在线状态只保存在内存中，重启后清空。

## 9. QUIC 与性能参数

服务端：

```toml
[quic]
initial_mtu = 1200
min_mtu = 1200
gso = true
pmtu = true
send_window = 16777216
receive_window = 8388608
max_idle_time = "30s"
max_concurrent_streams = 1280

[quic.congestion_control]
controller = "bbr" # bbr | bbr3 | cubic | new_reno
initial_window = 1048576
```

客户端在 `[relay]` 下提供对应的拥塞控制、窗口、MTU、GSO 和 PMTU 参数。除非已经通过链路测试确认问题，不建议偏离 MTU `1200`；错误 MTU 往往表现为握手成功但大流量卡顿。

## 10. Docker 部署

### 10.1 Linux 一键部署脚本

仓库提供基于预编译 Release 和 systemd 的引导式部署脚本。直接运行后，向导会依次询问版本、TLS 方式、域名、端口、用户凭据和防火墙设置，并在修改系统前显示汇总信息供确认：

```bash
sudo bash scripts/deploy-server.sh \
  --domain tuic.example.com
```

也可以直接从仓库执行：

```bash
curl -fsSL https://raw.githubusercontent.com/tuxco-de/tuic/main/scripts/deploy-server.sh | \
  sudo bash -s -- --domain tuic.example.com
```

命令行参数会作为向导默认值，按 Enter 即可采用。需要无人值守部署时，提供完整参数并添加 `--non-interactive`：

```bash
sudo bash scripts/deploy-server.sh \
  --non-interactive \
  --tls acme \
  --domain tuic.example.com \
  --email admin@example.com \
  --open-firewall
```

脚本会自动识别 Linux 架构、下载服务端、生成 UUID/密码和 TOML 配置、创建低权限用户并启动 systemd 服务。默认使用 ACME；还支持自签名和已有证书：

```bash
# 自签名，仅建议测试
sudo bash scripts/deploy-server.sh \
  --tls self-signed \
  --domain 203.0.113.10

# 已有证书
sudo bash scripts/deploy-server.sh \
  --tls manual \
  --domain tuic.example.com \
  --certificate /root/fullchain.pem \
  --private-key /root/privkey.pem
```

重复执行默认保留 `/etc/tuic/config.toml`，用于只更新二进制和 systemd 服务。需要重新生成配置时使用 `--force-config`，原配置会先按时间戳备份。查看全部参数：

```bash
bash scripts/deploy-server.sh --help
```

### 10.2 Docker

```bash
docker run --name tuic-server \
  --restart unless-stopped \
  -p 443:443/udp \
  -v /path/to/config:/etc/tuic:ro \
  -d ghcr.io/itsusinn/tuic-server:latest
```

镜像默认从 `/etc/tuic` 搜索配置。若使用 ACME 或需要写入证书缓存，不要将整个数据目录只读挂载，应把配置和可写 `data_dir` 分开挂载。

Compose 示例：

```yaml
services:
  tuic-server:
    image: ghcr.io/itsusinn/tuic-server:latest
    restart: unless-stopped
    ports:
      - "443:443/udp"
    volumes:
      - ./config:/etc/tuic:ro
      - ./data:/var/lib/tuic
```

对应配置中设置 `data_dir = "/var/lib/tuic"`。

## 11. 验证与排障

### 11.1 启动前检查

```bash
tuic-server --help
tuic-client --help
cargo test --workspace
```

配置采用严格字段校验。出现 `unknown field` 时，应检查字段层级和拼写，不要假设未知字段会被忽略。

### 11.2 常见问题

| 现象 | 检查项 |
| --- | --- |
| 客户端超时 | UDP 端口、防火墙、安全组、服务端监听地址、域名解析 |
| TLS 验证失败 | 证书 SAN、SNI、系统时间、客户端 CA、ACME 是否回退自签名 |
| 认证失败 | UUID 和密码是否与 `[users]` 完全一致 |
| SOCKS5 TCP 可用但 UDP 不可用 | 应用是否支持 SOCKS5 UDP、`udp_relay_mode`、本地 UDP 会话超时 |
| 内网目标被阻止 | ACL 是否显式放行，`drop_private`/`drop_loopback` 是否符合预期 |
| 大包或高吞吐异常 | MTU、PMTU、GSO、窗口、运营商 UDP 限制 |
| 伪装后端失败 | URL 必须为绝对 URL；IP 后端必须配置 `reverse_proxy_hostname` |
| REST 返回 401 | Bearer token 与 `restful.secret` 是否一致 |

提高日志级别：

```toml
log_level = "debug" # trace | debug | info | warn | error | off
```

服务端还支持结构化日志：

```toml
[log]
format = "json"
compact = false
log_file = "/var/log/tuic/server.log"
log_rotation = "daily" # never | hourly | daily
```

## 12. 生产部署检查清单

- 使用可信证书，客户端未启用 `skip_cert_verify`。
- UUID/密码和 REST 密钥为独立随机值。
- 仅开放 TUIC UDP 端口；REST 仅在回环或管理网络监听。
- 默认阻止回环和私网，ACL 只放行必要目标。
- 明确是否接受 0-RTT 重放风险。
- 为服务端配置进程守护、日志轮转和可写数据目录。
- 在实际网络上验证 TCP、UDP、IPv4/IPv6 和 MTU。
