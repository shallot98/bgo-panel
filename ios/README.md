# bgo面板 iOS App（原生客户端）

原生 iOS 客户端：零第三方依赖（纯 Swift + UIKit），数据通过 REST API 直接对接自建的 `bgo-panel`（`https://bgp.cenai.de`）。

## 特性

- **原生房间监控列表**：
  - 120Hz 流畅列表，支持下拉刷新（`UIRefreshControl`）；
  - 醒目状态指示：🔴 录制中、🟢 监听中、⚪ 已停止、⚠️ 备援接管；
  - dyzb AI 衣着评分徽标联动（⭐ 0-5 分）；
  - 原生手势：向右滑一键开关监听，向左滑修改模式或删除房间，带触觉震动（Taptic Engine）。
- **智能加房**：
  - 打开或切回前台自动侦测剪贴板抖音链接/口令文案，一键自动填入；
  - 快捷模式选择（永久、临时 24h、只录本场、自定义）；
  - 支持指定目标服务器（boh、boh2、hwsg）。
- **运行总览仪表盘**：
  - 2x2 KPI 指标卡（在录、监听、总数、备援状态）；
  - 多服务器节点列表与延迟监控。
- **渐进式 Web 兜底**：
  - 内嵌 WKWebView 自动注入鉴权凭据，首发即可无缝使用备援规则、运行日志、存储详情等全部高级后台。
- **双端分发包**：
  - 同时提供 TrollStore 无签名 IPA 与 RootHide/rootless 越狱 deb。

## 工程结构

```
ios/
  project.yml                 XcodeGen 工程定义（仓库不提交 .xcodeproj）
  BgoPanel/
    AppDelegate.swift         应用入口与鉴权路由
    MainTabBarController.swift 主导航容器（监控、总览、设置）
    RoomsViewController.swift 监控列表（下拉刷新、滑动操作、排序）
    RoomCell.swift            房间单行卡片（头像、状态灯、模式标签、评分）
    AddRoomViewController.swift 快速加房浮层（剪贴板提取、模式选择）
    OverviewViewController.swift 状态仪表盘（KPI 卡片、多节点状态）
    MoreViewController.swift  设置与 Web 兜底入口列表
    WebViewController.swift   内嵌 WKWebView（凭据自动注入）
    LoginViewController.swift 连接配置与 Token 登录
    APIClient.swift           原生 URLSession 网络层与鉴权注入
    Models.swift              Codable 数据模型（Room、Overview、HostItem）
    Support.swift             UserDefaults 持久化、触感反馈、图片缓存、主题
    Info.plist                应用配置（暗色外观锁定、支持本地网络测试）
    Assets.xcassets           AppIcon 与背景色
  tools/make-icon.sh          从图片切全套 AppIcon 脚本
.github/workflows/ios-ipa.yml macOS 自动化 CI 构建流水线
```

## 构建

### 本地构建（macOS + Xcode）

```bash
brew install xcodegen
cd ios
xcodegen generate
xcodebuild -project BgoPanel.xcodeproj -scheme BgoPanel -configuration Release \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

### GitHub Actions 自动化构建

推送到 `main` 分支后，GitHub Actions 自动在 `macos-15` runner 编译、签名，并在 `ubuntu-latest` runner 打包 RootHide deb，自动发布到 GitHub Releases 的 `ios-latest` 固定标签。

## 安装指南

- **TrollStore（巨魔商店）**：下载 `BgoPanel-unsigned.ipa`，手机中用 TrollStore 打开并安装（永不掉签）。
- **越狱环境（RootHide / Dopamine）**：下载 `BgoPanel_iphoneos-arm64.deb`，执行 `dpkg -i BgoPanel_*.deb && uicache -a`。
- **自签侧载**：AltStore 或 Sideloadly 导入 IPA 用 Apple ID 自签。
