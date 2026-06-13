# TUIC 功能实现分析与精简建议

本文档对当前 TUIC 代理工具库（包含 `tuic-core`, `tuic-server`, `tuic-client`）的核心功能模块进行了梳理，并以脑图格式总结。同时在文末分析了哪些功能可以进行精简或解耦，以提升整体架构的轻量化。

## TUIC 功能脑图

| 核心组件 | 模块 | 功能描述 |
| --- | --- | --- |
| **tuic-core** (协议核心) | QUIC 通信支持 | 基于 quinn 的底层可靠传输与多路复用 |
| | TUIC 协议指令 | Authenticate (用户认证)、Connect (TCP)、Packet (UDP)、WindowUpdate (流控) |
| | 地址与封包解析 | SOCKS5 地址结构解析及域名封包处理 |
| | 加密层 | 统一采用 `ring` 实现加密支持，去除多余后端 |
| **tuic-server** (服务端) | 入站与认证 (Inbound) | 基于 QUIC 连接监听、UUID 身份验证、并发客户端限流控制 |
| | 出站路由 (Outbound) | 双栈支持 (IPv4/IPv6 优先)、网络设备绑定、上游 SOCKS5 代理级联 |
| | 访问控制 (ACL) | 基于自定义规则解析、域名/IP/CIDR 匹配、策略 (放行/拒绝/劫持) |
| | 伪装功能 (Camouflage) | 默认开启防探测伪装，对非协议标准流量默认返回静态 400 页面 |
| | Web 管理与遥测 | 基于 Axum 的 RESTful API、连接状态与流量统计指标导出 |
| | TLS 与证书 | 本地静态证书 (PEM/DER) 热加载，集成至 `deploy-server.sh` 使用 acme.sh |
| **tuic-client** (客户端) | 本地入站代理 | 提供 SOCKS5 (TCP/UDP) 以及 HTTP 协议的本地代理入口 |
| | QUIC 出站 | 零散 UDP 包聚合与传输、TCP 多路复用 (MUX) |
| | 拥塞控制与优化 | 支持 BBRv3 / CUBIC / NewReno 算法，以及基于 0-RTT 的快速重连 |

## 功能精简与解耦分析 (Simplification & Decoupling)

根据当前仓库的代码和依赖分析，TUIC 为了提供开箱即用的体验，曾内置了较多外围功能。为了追求极致的轻量化并提升安全性与易维护性，本项目目前已完成以下核心优化：

### 1. HTTP/3 伪装与反向代理 (Camouflage) - 已重构
- **现状**：此功能已精简。不再使用 `reqwest` 反向代理，现已将伪装功能（Camouflage）默认硬编码开启。遇到非 TUIC 的探测流量时，统一直接返回静态的 `400 Bad Request` 页面，极大减少了上层 HTTP 代理和依赖带来的臃肿体积。

### 2. 自动 ACME 证书签发 (Auto-SSL) - 已移除
- **现状**：已移除内置的 `rustls-acme`。
- **优化**：证书申请交由专门的工具处理。我们更新了自动化部署脚本（`deploy-server.sh`），在其中集成了外部 `acme.sh` 签发逻辑。服务端专注做核心代理，仅负责读取和热加载本地已部署完毕的证书与密钥文件。

### 3. RESTful API 管理面板接口
- **现状**：保留了一套用于查看在线客户端、断开连接和限流的 RESTful HTTP 接口。
- **详情**：接口调用若配置了 `secret`，则必须在请求头中携带 `Authorization: Bearer <secret>`。具体接口定义已移至单独的 `docs/api.md` 以便详细记录。

### 4. 旧版配置兼容与加密层 - 已精简
- **现状**：所有多余的旧版平铺配置回退支持已彻底移除。
- **加密库**：移除了多余的加密库（如 AWS-LC），当前服务端与客户端统一使用 `ring` 作为底层加密实现，大幅简化了编译要求并消除了特征标志之间的冗余。

