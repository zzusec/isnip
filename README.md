# iSnip for macOS

原生纯 Swift 打造的 **macOS 专业级极速截图标注、智能无损压缩与离线 OCR 工具**（灵感致敬 [bd-dxg/airsnip](https://github.com/bd-dxg/airsnip)）。基于 AppKit / ScreenCaptureKit / CoreGraphics / CoreText / Vision 构建，**不套 Electron / WebView 运行时、常驻菜单栏待机 0% CPU**。

## 核心特性

- **瞬时零抖动冻结抓屏与窗口识别**：全局热键（默认 `F1`）瞬时原亮度冻结屏幕，悬停智能高亮独立桌面窗口（自动过滤最大化背景窗避免全屏误选），配备 11×11 光学像素放大镜、`#HEX` / `RGB` 取色（`C` / `⇧C`）与 `Shift+F1` **再次截图**。
- **内置 `pngquant + oxipng` 智能无损 PNG 压缩（默认开启）**：
  - 应用包内置 `pngquant --speed 1` + `oxipng -o max --strip safe` 双引擎压缩管线，无需手工安装命令行依赖。
  - 典型 1.2 MB Retina 高清截图可直降至约 0.3~0.4 MB（体积缩减 60%~75%），肉眼几乎无差异；支持在设置面板与保存对话框随时开关或切换 `--quality` 档位（视觉无损 / `65-90` / `45-75`）。
  - 剪贴板复制同样支持零延迟后台静默压缩（剔除冗余巨型 TIFF 数据），直接粘贴到网页、IM 或文档更轻快。
- **Liquid Glass 16 项精简悬浮工具栏与 10 种矢量标注**：
  - 矩形（含内侧圆角控制柄）、椭圆、直线、三次贝塞尔曲线箭头、平滑手绘、三次盒式高斯模糊、原生中文输入法文本、自动递增序号徽标、聚光灯与正片叠底荧光笔；支持 8 向缩放、二次编辑与 100 步撤销重做。
  - 二级属性气泡与连续渐变 HSV 取色器按需展开；5 组共 24 项工具栏槽位支持胶囊点选定制。
- **手动滚动长截图 (`S`)**：穿透视口滚动，基于 FNV-1a 行哈希重叠一致性校验与固定页眉/页脚自动剥离，支持上下双向拼接、实时缩略图预览与 `⌘Z` 分段回退。
- **置顶贴图 (`F3`)**：支持多张贴图置顶对比、滚轮中心缩放、`⌘`/`⌃`+滚轮调节透明度、圆角发光边框开关、鼠标点击穿透与 `Space` 原地补画标注。
- **全场景本地离线 Vision OCR 与二维码解析（`F2` / `T`）**：支持直接框选识别、截图内识别、贴图按 `T` 识别、长截图整图提取及剪贴板/本地图片识别；内置段落软换行智能合并与二维码一键直达，全程端侧离线推理，绝不上传云端。

## 构建与验证

```sh
# 1. 应用构建、签名校验、内置压缩引擎检查与端到端冒烟测试
sh macos/scripts/test-app-smoke.sh

# 2. 核心库单元测试与发布策略检查
(cd macos && swift test)
python3 macos/scripts/test-release-policy.py

# 3. 本机编译并安装到 /Applications/iSnip.app
sh macos/scripts/install-local.sh --no-pull
```

## 开源许可

本项目源码遵循 [GPL-3.0-only](LICENSE) 许可证；内嵌独立命令行工具遵循各自开源许可（`pngquant` GPL-3.0、`oxipng` MIT）。
