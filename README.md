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
   HTTPTransport ──────► DJOneHub 核心（子进程）──libusb── 4G 模块
```

App 启动时把核心作为子进程拉起，端口向内核申请而非写死，因此不会与你手动运行的
`djonehub` 抢占默认的 7575。

界面代码只依赖 `ModemTransport` 协议，目前仅有 HTTP 一个实现。这是刻意留下的接缝：
若将来 iPad 直连方案成立，只需新增一个基于 DriverKit 的实现，视图层无需改动。

核心进程通过 `-parent-pid` 感知父进程消失后自行退出，所以 App 崩溃或被强制退出时
不会遗留占用 USB 接口的孤儿进程。

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
| AT 调试 | 未开始 |
| 短信 | 未开始 |
| 网络与流量 | 未开始 |
| eSIM Profile | 未开始 |

核心自带的网页界面仍然可用，本项目是增量而非替代。
