# Spectty 项目总览

本文档面向维护者、贡献者和需要快速理解 Spectty 实现细节的开发者，基于当前仓库源码整理项目架构、模块职责、关键数据流、安全机制、测试覆盖与实现边界。

`README.md` 仍然是项目对外入口，偏产品介绍和高层架构；本文档聚焦“代码是如何组织与运行的”。

## 1. 项目定位

Spectty 是一个面向 iOS 的原生 SSH / Mosh 终端应用，核心特点包括：

- 使用 Swift 6 开发，部署目标为 iOS 18+
- UI 采用 SwiftUI 外层壳 + UIKit / Metal 终端视图
- 同时支持 SSH 与原生 Swift clean-room Mosh 实现
- 终端渲染使用 Metal，终端状态处理由自有 VT 状态机驱动
- 凭据与恢复状态优先保存在本地 Keychain
- 不集成账号体系、分析埋点或遥测

从实现上看，Spectty 不是简单把远端输出塞进文本控件，而是把“连接传输”“终端仿真”“UI 渲染”“凭据存储”拆成了独立层级，便于维护和替换实现。

## 2. 仓库结构

仓库主要由主 App 工程和四个本地 Swift Package 组成。

### 2.1 顶层目录

- `Spectty/`：主 iOS App，包含模型、ViewModel、页面和服务
- `Packages/SpecttyTransport/`：SSH / Mosh 传输层
- `Packages/SpecttyTerminal/`：终端状态机、缓冲区、按键编码
- `Packages/SpecttyUI/`：Metal 渲染、输入、手势与 SwiftUI 桥接
- `Packages/SpecttyKeychain/`：Keychain 访问、密钥生成、私钥导入
- `SpecttyTests/`：主 App 层测试
- `README.md`：英文入口文档
- `PRIVACY.md`：隐私声明
- `scripts/`：辅助脚本
- `.github/workflows/build.yml`：CI 构建流程

### 2.2 模块职责总览

| 模块 | 职责 |
| --- | --- |
| `Spectty` | App 启动、连接列表、会话管理、隐私锁、SwiftData 持久化 |
| `SpecttyTransport` | 统一抽象终端连接传输，提供 SSH 与 Mosh 两种实现 |
| `SpecttyTerminal` | 维护终端状态、解析 VT 序列、编码键盘输入 |
| `SpecttyUI` | 把终端状态渲染到屏幕，并接收键盘/手势输入 |
| `SpecttyKeychain` | 存取凭据、管理密钥、导入 OpenSSH 私钥 |

## 3. 运行时整体架构

Spectty 的运行链路可以概括为：

1. `SpecttyApp` 启动应用，创建 SwiftData `ModelContainer`
2. `ContentRoot` 注入 `ConnectionStore`、`SessionManager`、`PrivacyLockManager`
3. 用户从连接列表选择一个 `ServerConnection`
4. `SessionManager.connect(to:)` 根据连接配置创建 `SSHTransport` 或 `MoshTransport`
5. `TerminalSession` 把 transport 与 `GhosttyTerminalEmulator` 连接起来
6. 远端数据进入 transport 后，通过 `incomingData` 送入终端状态机
7. `TerminalView` / `TerminalMetalView` 读取终端状态并完成 Metal 渲染
8. 本地键盘、手势和粘贴输入经过 `KeyEncoder` 编码后重新送回 transport

对应关系与职责边界主要体现在以下文件：

- `Spectty/SpecttyApp.swift`
- `Spectty/ViewModels/SessionManager.swift`
- `Spectty/Models/TerminalSession.swift`
- `Packages/SpecttyTransport/Sources/SpecttyTransport/TransportProtocol.swift`
- `Packages/SpecttyTerminal/Sources/SpecttyTerminal/GhosttyTerminalEmulator.swift`
- `Packages/SpecttyUI/Sources/SpecttyUI/TerminalView.swift`

## 4. App 层：启动、连接与会话管理

### 4.1 应用入口

`Spectty/SpecttyApp.swift` 是应用启动入口，主要职责：

- 创建 `ModelContainer`，并绑定 `SpecttyMigrationPlan`
- 通过环境注入 `SessionManager` 与 `PrivacyLockManager`
- 在首次进入界面时自动调用 `sessionManager.autoResumeSessions()`
- 在前后台切换时触发：
  - 前台：`checkAllConnections()`、`appDidBecomeActive()`
  - 后台：`saveActiveSessions()`、`appDidEnterBackground()`

这说明会话恢复与隐私保护都不是零散逻辑，而是直接挂在 App 生命周期上。

### 4.2 连接存储

`Spectty/ViewModels/ConnectionStore.swift` 负责通过 SwiftData 管理连接列表：

- 获取连接并按 `sortOrder` / `name` 排序
- 新增连接
- 克隆连接
- 删除连接
- 保存连接顺序或修改

需要特别注意：连接的结构化元数据通过 SwiftData 持久化，但真正的敏感凭据并不直接持久化在模型里。删除连接时还会联动清理 Keychain 中对应密码或私钥。

### 4.3 连接模型与迁移

`Spectty/Models/ServerConnection.swift` 定义了：

- 传输类型：`ssh` / `mosh`
- 认证方式：`password` / `publicKey` / `keyboardInteractive`
- Mosh 预设与高级选项
- Keychain account 引用
- 启动命令、排序字段等

文件中同时保留了 `SpecttySchemaV1` 到 `SpecttySchemaV4`，说明该模型已发生多轮演进，尤其与 Mosh 相关字段有关。

一个非常重要的实现细节是：

- `password` 被标记为 `@Transient`

这意味着密码只在运行期短暂存在，连接元数据与敏感凭据是分层存储的。

### 4.4 SessionManager

`Spectty/ViewModels/SessionManager.swift` 是整个应用的会话控制中心，负责：

- 根据 `ServerConnection` 创建 transport
- 从 Keychain 读取密码或私钥
- 组装 `TerminalSession`
- 维护当前活动 session 与 session 列表
- 批量 resize 已打开的终端
- 自动恢复已保存的 Mosh 会话
- 在后台保存活跃 Mosh session 状态

其中 `connect(to:)` 是连接主入口，会根据 `connection.transport` 动态选择：

- `SSHTransport`
- `MoshTransport`

这也是 App 层与底层协议层的主要解耦点。

## 5. TerminalSession：连接 transport 与终端仿真层

`Spectty/Models/TerminalSession.swift` 表示一个活动终端会话。它负责把：

- 底层 `TerminalTransport`
- 上层 `GhosttyTerminalEmulator`

连接成完整的数据通路。

关键职责包括：

- `start()`：连接 transport，并开始监听状态流与数据流
- 收到远端数据时调用 `emulator.feed(data)`
- 将本地键盘事件转成终端字节序列并发送
- 处理终端 resize
- 监听连接状态变化并触发自动重连
- 在连接成功后发送 startup command
- 处理终端回包，如 DSR / DA / OSC 查询响应

一个值得注意的实现细节是 `enqueueOutboundSend(_:)`：

- 它通过串行任务链保证突发输入的发送顺序

这对软键盘连续输入、手势输入或自动响应序列的时序一致性很重要。

## 6. 传输层：SpecttyTransport

`Packages/SpecttyTransport/Sources/SpecttyTransport/TransportProtocol.swift` 定义了 transport 抽象边界。

### 6.1 TerminalTransport 协议

统一抽象包含：

- `state: AsyncStream<TransportState>`
- `incomingData: AsyncStream<Data>`
- `connect()`
- `disconnect()`
- `send(_:)`
- `resize(columns:rows:)`
- `checkConnection()`

这意味着上层不需要关心具体是 SSH 还是 Mosh，只要遵守这个协议即可。

### 6.2 ResumableTransport

`ResumableTransport` 在 `TerminalTransport` 基础上扩展了：

- `exportSessionState(...) -> MoshSessionState?`

当前这个能力主要服务于 Mosh 会话持久化与恢复。

## 7. SSH 实现

SSH 相关实现位于：

- `Packages/SpecttyTransport/Sources/SpecttyTransport/SSH/SSHTransport.swift`
- `Packages/SpecttyTransport/Sources/SpecttyTransport/SSH/SSHAuthentication.swift`
- `Packages/SpecttyTransport/Sources/SpecttyTransport/SSH/SSHChannel.swift`
- `Packages/SpecttyTransport/Sources/SpecttyTransport/SSH/SSHHostKeyTrustStore.swift`

从整体设计看，SSH 链路负责：

1. 建立 TCP / SSH 连接
2. 处理密码或公钥认证
3. 校验 host key
4. 打开 session channel
5. 请求 PTY 与 shell
6. 收发终端数据
7. 处理 resize 与状态变化

### 7.1 Host key 信任模型

从测试和信任存储设计看，当前主机密钥验证采用的是 TOFU（Trust On First Use）风格：

- 第一次看到某个 `host:port` 的 key 时建立信任
- 后续若 key 变化则视为 mismatch
- 用户可删除后重新信任

这一点在 `Packages/SpecttyTransport/Tests/SpecttyTransportTests/SSHHostKeyTests.swift` 中有明确覆盖。

## 8. Mosh 实现

Mosh 是 Spectty 最有特色的部分之一，相关代码位于：

- `Packages/SpecttyTransport/Sources/SpecttyTransport/Mosh/MoshTransport.swift`
- `Packages/SpecttyTransport/Sources/SpecttyTransport/Mosh/MoshBootstrap.swift`
- `Packages/SpecttyTransport/Sources/SpecttyTransport/Mosh/MoshNetwork.swift`
- `Packages/SpecttyTransport/Sources/SpecttyTransport/Mosh/MoshSSP.swift`
- `Packages/SpecttyTransport/Sources/SpecttyTransport/Mosh/MoshCrypto.swift`
- `Packages/SpecttyTransport/Sources/SpecttyTransport/Mosh/MoshSessionState.swift`
- `Packages/SpecttyTransport/Sources/SpecttyTransport/Mosh/STUNClient.swift`

### 8.1 建连流程

`MoshTransport.connect()` 的核心流程是：

1. 先做一次短超时 NAT 检测
2. 通过 `MoshBootstrap.start(...)` 走 SSH bootstrap
3. 远端执行 `mosh-server` 并解析 `MOSH CONNECT <port> <key>`
4. 用返回的 key 建立加密上下文
5. 通过 `MoshNetwork` 建立 UDP 通信
6. 启动 `MoshSSP` 同步状态
7. 把远端终端输出通过 `incomingData` 交给上层

### 8.2 会话恢复

Mosh 的恢复能力是当前实现中的重点能力之一：

- `MoshTransport.exportSessionState(...)` 导出 host、port、key 和 SSP 序列号
- `SessionManager.saveActiveSessions()` 在 App 进入后台时保存状态
- `MoshSessionStore` 将状态编码后保存到 Keychain
- `SessionManager.autoResumeSessions()` 在应用启动时恢复新鲜会话
- 恢复时直接走 `MoshTransport(resuming:config:)`，跳过 SSH bootstrap

需要注意的是：

- 当前自动恢复链路主要围绕 **Mosh session** 实现
- 文档不应将其泛化为“SSH 具备同等恢复语义”

### 8.3 Mosh 的实现价值

从代码与测试可以看出，这不是简单的“调用外部二进制壳子”，而是完整实现了多项核心机制：

- bootstrap
- UDP 收发
- roaming
- NAT 诊断
- AES-128-OCB3
- SSP 状态同步
- session resume

## 9. 终端仿真层：SpecttyTerminal

`Packages/SpecttyTerminal` 负责“终端应该长什么样、如何解释字节流、如何编码按键”。

### 9.1 GhosttyTerminalEmulator

`Packages/SpecttyTerminal/Sources/SpecttyTerminal/GhosttyTerminalEmulator.swift` 提供 `TerminalEmulator` 实现，内部核心依赖：

- `TerminalState`
- `VTStateMachine`
- `KeyEncoder`

主要能力：

- `feed(_:)`：处理远端数据
- `resize(columns:rows:)`
- `encodeKey(_:)`
- 提供 scrollback 访问
- 提供回包与剪贴板回调

### 9.2 VT 状态机与终端状态

终端状态相关核心文件包括：

- `TerminalState.swift`
- `TerminalBuffer.swift`
- `VTStateMachine.swift`
- `KeyEncoder.swift`

它们共同维护：

- 主屏 / 备用屏
- 光标状态
- 样式与颜色
- scrollback
- 终端模式
- 按键序列编码

### 9.3 关于 ghostty 的当前状态

虽然项目命名与结构中包含 `GhosttyTerminalEmulator`、`CGhosttyVT`，但根据当前代码，必须明确以下事实：

- `Packages/SpecttyTerminal/Sources/CGhosttyVT/ghostty_vt_stub.c` 仍是 stub / no-op 实现
- `GhosttyTerminalEmulator` 当前主要依赖 Swift 自研 `VTStateMachine`
- 现阶段更准确的描述是：**项目为未来接入 libghostty 预留了边界，但当前并未完整切换到真实 libghostty 终端引擎**

这一点在文档中必须写清楚，避免误导读者。

## 10. UI 与渲染层：SpecttyUI

UI 层主要负责把终端状态可视化，并把用户输入转换为终端输入事件。

关键文件包括：

- `Packages/SpecttyUI/Sources/SpecttyUI/TerminalView.swift`
- `Packages/SpecttyUI/Sources/SpecttyUI/TerminalMetalView.swift`
- `Packages/SpecttyUI/Sources/SpecttyUI/TerminalMetalRenderer.swift`
- `Packages/SpecttyUI/Sources/SpecttyUI/GestureHandler.swift`
- `Packages/SpecttyUI/Sources/SpecttyUI/TextSelectionView.swift`

### 10.1 SwiftUI 与 UIKit/Metal 桥接

`TerminalView.swift` 是 `UIViewRepresentable` 包装层，负责：

- 在 SwiftUI 中嵌入 `TerminalMetalView`
- 传递键盘输入、粘贴、resize、边缘滑动等回调
- 响应 SwiftUI 重绘时的 emulator 切换
- 同步字体、主题、光标样式

### 10.2 TerminalMetalView 与 TerminalMetalRenderer

从结构上看：

- `TerminalMetalView` 是交互核心视图
- `TerminalMetalRenderer` 是实际渲染执行者

这意味着 Spectty 不是依赖 `UITextView` 或 WebView 来模拟终端，而是使用专用 Metal 终端渲染链。

## 11. 凭据、安全与隐私

### 11.1 Keychain 分层

敏感信息的存储主要由 `Packages/SpecttyKeychain` 负责，关键文件包括：

- `KeychainManager.swift`
- `KeyGenerator.swift`
- `SSHKeyImporter.swift`

项目当前的安全分层可以概括为：

- SwiftData：连接元数据
- Keychain：密码、私钥、Mosh 恢复状态、PIN 等敏感信息

### 11.2 私钥与凭据处理

结合 `SessionManager.swift` 与 `ConnectionStore.swift` 可知：

- 密码通常以 `password-<uuid>` 形式存入 Keychain
- 私钥通常以 `private-key-<uuid>` 形式存入 Keychain
- 连接克隆时会复制凭据到新的 Keychain account
- 删除连接时会清理相关敏感数据

### 11.3 隐私锁

`Spectty/Services/PrivacyLockManager.swift` 提供：

- PIN 的哈希存储与校验
- 生物识别可用性检测
- 前后台切换锁屏
- 生物识别解锁

这套机制与 App 生命周期联动，用来避免应用回前台时直接暴露终端内容。

### 11.4 隐私声明

根据 `PRIVACY.md`，当前项目的明确承诺包括：

- 不收集、存储、传输或分享个人数据、使用数据、analytics、telemetry
- 网络连接仅在用户主动发起 SSH 连接时发生
- 凭据保存在本地设备 Keychain
- 不集成第三方广告、跟踪或分析服务

中文文档中的隐私描述应以 `PRIVACY.md` 为准，不应自行扩展额外承诺。

## 12. 测试覆盖现状

当前测试更偏向“关键底层能力验证”，而不是全栈 UI 自动化。

### 12.1 已覆盖较好的部分

- `Packages/SpecttyTransport/Tests/SpecttyTransportTests/MoshTests.swift`
  - OCB3 RFC 向量
  - 加解密 round-trip
  - tamper 检测
  - packet framing
  - protobuf codec
- `Packages/SpecttyTransport/Tests/SpecttyTransportTests/SSHHostKeyTests.swift`
  - 首次信任
  - key 变更检测
  - 持久化后重载
  - 删除已信任主机后重新信任
- `Packages/SpecttyKeychain/Tests/...`
  - OpenSSH 私钥导入
- `SpecttyTests/...`
  - 连接克隆、迁移等 App 侧逻辑

### 12.2 当前覆盖边界

文档应准确表述为：

- 底层协议、信任与迁移逻辑覆盖较好
- UI 渲染、完整终端交互链路、端到端系统行为不是当前测试重点

不宜写成“测试已经完整覆盖整条功能链路”。

## 13. 构建方式

当前仓库中的构建入口主要有两个：

- `README.md` 中的 `xcodebuild build -scheme Spectty -destination 'generic/platform=iOS'`
- `.github/workflows/build.yml` 中的 iOS Simulator 构建

CI 当前主要承担“项目是否能通过构建”的职责，而不是完整测试矩阵。

## 14. 当前实现边界与注意事项

在阅读或继续扩展本项目时，建议先牢记以下边界：

1. `libghostty` 目前仍是预留接入结构，不是完整运行时依赖
2. `GhosttyTerminalEmulator` 当前主要由 Swift `VTStateMachine` 驱动
3. 自动恢复重点是 Mosh，会话恢复语义不要泛化到所有 transport
4. 连接元数据与敏感凭据分层存储，不能把 SwiftData 当成凭据仓库理解
5. 测试优势在底层协议、信任与迁移，不在 UI 全链路

## 15. 建议阅读顺序

如果要快速理解项目，建议按下面顺序阅读：

1. `README.md`
2. `Spectty/SpecttyApp.swift`
3. `Spectty/ViewModels/SessionManager.swift`
4. `Spectty/Models/TerminalSession.swift`
5. `Spectty/Models/ServerConnection.swift`
6. `Packages/SpecttyTransport/Sources/SpecttyTransport/TransportProtocol.swift`
7. `Packages/SpecttyTransport/Sources/SpecttyTransport/SSH/SSHTransport.swift`
8. `Packages/SpecttyTransport/Sources/SpecttyTransport/Mosh/MoshTransport.swift`
9. `Packages/SpecttyTerminal/Sources/SpecttyTerminal/GhosttyTerminalEmulator.swift`
10. `Packages/SpecttyUI/Sources/SpecttyUI/TerminalView.swift`
11. `Packages/SpecttyTransport/Tests/SpecttyTransportTests/MoshTests.swift`
12. `Packages/SpecttyTransport/Tests/SpecttyTransportTests/SSHHostKeyTests.swift`

通过这条路径，可以较快建立从 App 层到 transport、再到底层终端和 UI 的完整认知。
