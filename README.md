# DJOneHubApp

面向**大疆第一代 4G 模块**的 macOS 原生管理界面，用 SwiftUI 编写。

它不实现任何模块协议，而是驱动 [DJOneHub](https://github.com/ab300819/DJOneHub) 核心——
短信 PDU 编解码、eSIM/SGP.22 APDU、MBIM、QMI 全部由那边的 Go 代码承担，并已有成套测试。
本项目只负责界面和进程编排。

> [!IMPORTANT]
> 非官方第三方项目，与 DJI、Quectel、运营商及 eSIM 卡片厂商不存在隶属、授权或合作关系。

## 与核心的关系

```
   SwiftUI 界面
        │  ModemTransport 协议
        ▼
   StdioTransport ──管道──► DJOneHub 核心（子进程，-stdio）──libusb── 4G 模块
```

App 把核心作为子进程拉起，通过它自己的 stdin/stdout 交换行分隔 JSON。

**不监听任何端口。** 这一点是刻意的：核心的 HTTP API 没有任何鉴权，若开在 TCP 端口上，
本机任意进程都能发送任意 AT 指令或删除 eSIM Profile。网页界面受浏览器限制只能走 HTTP，
原生 App 没有理由继承这个约束。

生命周期也因此免费获得：App 一旦退出——包括崩溃和被强制退出——管道写端关闭，
核心读到 EOF 后自行结束，不会遗留占用 USB 接口的孤儿进程。

界面代码只依赖 `ModemTransport` 协议。这是刻意留下的接缝：iOS 禁止 App 派生子进程，
所以 iPad 版无法复用当前实现，届时需要新增一个基于 DriverKit 的传输层，但视图层不必改动。

## 构建与运行

需要 Xcode 与 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```sh
brew install xcodegen
make demo   # 演示数据，无需硬件
make run    # 接真实模块
```

`.xcodeproj` 由 `project.yml` 生成，不纳入版本管理，因此工程配置始终以可读文本形式 review。

## 核心二进制的查找顺序

1. App bundle 内置（发行形态）
2. 环境变量 `DJONEHUB_CORE` 指定的路径
3. 与本仓库**平级**的 `DJOneHub/dist/djonehub-macos`

开发时通常用第 3 种，即两个仓库并排 checkout：

```
.
├── DJOneHub/       # Go 核心
└── DJOneHubApp/    # 本项目
```

## 当前状态

| 页面 | 状态 |
| --- | --- |
| 模块状态 | 已实现 |
| 短信 | 已实现（收取、刷新、发送、清空模块存储） |
| AT 调试 | 已实现 |
| 网络与流量 | 未开始 |
| eSIM Profile | 未开始 |

核心侧 24 个方法均已就绪，后续页面只需在 `ModemTransport` 上补方法并写视图。

核心自带的网页界面仍然可用，本项目是增量而非替代。
