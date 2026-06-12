# TUIC

Delicately-TUICed 0-RTT proxy protocol

A fork of original TUIC repo https://github.com/tuic-protocol/tuic

## Documentation

- [System architecture design](docs/architecture.md)
- [Usage guide](docs/user-guide.md)
- [Linux one-click server deployment](scripts/deploy-server.sh)
- [Client configuration reference](tuic-client/README.md)
- [Server configuration reference](tuic-server/README.md)

Compared to origin, this fork's new features:

**Infrastructure & CI/CD:**
- In-tree [Docker image builds](https://github.com/Itsusinn/tuic/pkgs/container/tuic-server) with multi-platform support (linux/amd64, linux/arm64)
- Reusable CI/CD workflows with extensive cross-compilation support via [cross-rs](https://github.com/cross-rs/cross)
- Support for multiple platforms: Linux (GNU/musl), Windows (MSVC), macOS, FreeBSD, and more

**TLS & Security:**

- Automatic SSL/TLS certificate provisioning via ACME (Let's Encrypt) for domain or **IP**
- Self-signed certificate support
- Certificate auto hot-reload for zero-downtime updates
- `skip_cert_verify` option for client connections

**Performance & Stability:**
- JEMalloc allocator integration for better memory management
- AWS-LC-RS crypto provider for improved performance
- More active `max_concurrent_streams` strategy
- Rust edition 2024
- BBR3 congestion control algorithm support

**Server Features:**
- ACL (Access Control List) support with configurable outbound rules
- SOCKS5 outbound proxy support
- RESTful API with traffic statistics
- Network interface binding support
- Default localhost access protection
- Private/LAN address filtering for enhanced security

**Client Features:**
- TCP/UDP port forwarding support
- Local socket rebinding for better reliability

## Introduction

TUIC is a proxy protocol focusing on minimize the additional handshake latency caused by relaying as much as possible, as well as keeping the protocol itself being simple and easy to implement

TUIC is originally designed to be used on top of the [QUIC](https://en.wikipedia.org/wiki/QUIC) protocol, but you can use it with any other protocol, e.g. TCP, in theory

When paired with QUIC, TUIC can achieve:

- 0-RTT TCP proxying
- 0-RTT UDP proxying with NAT type [Full Cone](https://www.rfc-editor.org/rfc/rfc3489#section-5) 
- 0-RTT authentication
- Two UDP proxying modes:
    - `native`: Having characteristics of native UDP mechanism
    - `quic`: Transferring UDP packets losslessly using QUIC streams
- Fully multiplexed
- All the advantages of QUIC, including but not limited to:
    - Bidirectional user-space congestion control
    - Optional 0-RTT connection handshake
    - Connection migration

Fully-detailed TUIC protocol specification can be found in [SPEC.md](https://github.com/proxy-rs/wind/blob/main/crates/wind-tuic/SPEC.md)

## Overview

There are 4 crates provided in this repository:

- **[tuic-core](tuic-core)** - Library. TUIC v5 protocol types, marshalling, connection model, and Quinn integration
- **[tuic-server](tuic-server)** - Binary and library. TUIC server, ACL/outbound routing, TLS/ACME, camouflage, and management API
- **[tuic-client](tuic-client)** - Binary and library. TUIC client, local SOCKS5 proxy, and TCP/UDP forwarding
- **[tuic-tests](tuic-tests)** - Integration tests covering client/server interoperability



## Contribute TUIC

[Search TODO in code base](https://github.com/search?q=repo%3AItsusinn%2Ftuic%20todo&type=code) or [Assist with Open Issues](https://github.com/Itsusinn/tuic/issues?q=label%3A%22help+wanted%22+is%3Aissue+is%3Aopen)

### Contributing Guidelines

Contributors should fork from the `main` branch and submit pull requests to the `main` branch. Please note that the `dev` branch may be force-pushed from time to time, so avoid basing your work on it.

## Contributors

Thanks to all the contributors who have helped improve TUIC!

<a href="https://github.com/Itsusinn/tuic/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=Itsusinn/tuic" />
</a>

## License

Code in this repository is licensed under [GNU General Public License v3.0](https://github.com/Itsusinn/tuic/blob/dev/LICENSE)

However, the concept of the TUIC protocol is license-free. You can implement, modify, and redistribute the protocol without any restrictions, even for commercial use
