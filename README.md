# bgo-panel

bililive-go 独立监控面板与原生 iOS 客户端。

- **Web 控制台**：`https://bgp.cenai.de`（后端 `server/panel.py`，运行于 `boh:9090`，无外部第三方依赖）
- **iOS 客户端**：`ios/`（纯 Swift 原生，XcodeGen 声明式工程，零外部三方依赖，支持 TrollStore / RootHide 越狱 / 侧载）

## 目录结构

```
bgo-panel/
  server/                     面板服务端（Python 3 标准库单进程）
    panel.py                  核心路由与多服务器代理转发、自动规则引擎
    index.html                桌面端深色控制台前端
    start.sh / stop.sh        启动与停止脚本
    watchdog.sh               30s 守卫脚本
  ios/                        原生 iOS App 客户端
    project.yml               XcodeGen 声明式工程定义
    BgoPanel/                 Swift 原生源码（UIKit / URLSession / WebKit）
    tools/make-icon.sh        AppIcon 切图工具
  .github/workflows/
    ios-ipa.yml               GitHub Actions 自动化编译、签名、打包 deb 并发布 Releases
```

## 客户端下载

每次提交代码到 `main` 分支，GitHub Actions 会自动编译并更新固定发行版：
- [BgoPanel-unsigned.ipa（TrollStore / 侧载）](https://github.com/shallot98/bgo-panel/releases/download/ios-latest/BgoPanel-unsigned.ipa)
- [BgoPanel_iphoneos-arm64.deb（RootHide / 越狱机）](https://github.com/shallot98/bgo-panel/releases/download/ios-latest/BgoPanel_iphoneos-arm64.deb)

首次打开填入服务器地址（默认 `https://bgp.cenai.de`）与 Web 设置页生成的 API Token 即可免密连接。
