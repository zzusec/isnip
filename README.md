# iSnip

原生纯 Swift 打造的 macOS 截图标注、智能无损压缩与离线 OCR 工具。基于 AppKit / ScreenCaptureKit / CoreGraphics / Vision 构建，常驻菜单栏待机 0% CPU。

## 下载安装

前往 [GitHub Releases](https://github.com/zzusec/isnip/releases/latest) 下载最新 `isnip-macos-arm64-v*.dmg`（macOS 14.0+，Apple Silicon），拖入 `/Applications` 即可使用。

## 核心特性

- **零抖动瞬时抓屏（`F1`）**：全屏原亮度静默冻结，悬停智能高亮独立桌面窗口（自动过滤最大化背景窗），支持 11×11 像素放大镜、`#HEX` / `RGB` 取色（`C` / `⇧C`）与 `⇧F1` 再次截图。
- **内置 `pngquant + oxipng` 无损压缩与默认目录直存**：应用内自带 `pngquant --speed 1` + `oxipng -o max --strip safe` 双引擎管线，无需额外安装命令行依赖；1.2 MB 级 Retina 截图可压至约 0.3~0.4 MB，剪贴板复制与本地导出同步生效。按 `⌘S` 默认直接静默保存至默认目录（免每次弹窗询问，支持自定义路径或 `⇧⌘S` 另存为）。
- **16 项毛玻璃工具栏与 10 种矢量标注**：矩形（可调圆角）、椭圆、直线、贝塞尔箭头、平滑手绘、高斯模糊、原生中文输入文本、递增序号、聚光灯、荧光笔；支持二次编辑、100 步撤销重做与 24 项槽位显隐定制。
- **滚动长截图（`S`）**：穿透视口滚动，行哈希重叠校验与固定页眉/页脚自动剥离，支持双向拼接与 `⌘Z` 分段回退。
- **置顶贴图（`F3`）**：多图置顶对比、滚轮缩放、`⌘`/`⌃`+滚轮调透明度、点击穿透与 `Space` 原地补画标注。
- **端侧离线 OCR 与二维码识别（`F2` / `T`）**：支持直接框选、截图内、贴图、长截图及剪贴板/本地图片识别，内置段落软换行合并与二维码直达，全程离线不上传云端。

## 本地构建与测试

```sh
# 应用构建、签名校验、内置压缩引擎检查与冒烟测试
sh macos/scripts/test-app-smoke.sh

# 单元测试与发布策略检查
(cd macos && swift test)
python3 macos/scripts/test-release-policy.py

# 本机编译并安装到 /Applications/iSnip.app
sh macos/scripts/install-local.sh --no-pull
```

## 开源许可

本项目遵循 [GPL-3.0-only](LICENSE) 许可证；内嵌独立命令行工具遵循各自开源许可（`pngquant` GPL-3.0、`oxipng` MIT）。
