# 应用图标

双层蓝紫色额度仪表对应项目的 5 小时和 7 天额度窗口，冰蓝色圆角底板呼应应用的玻璃质感界面。

- `AppIcon.png`：1024 × 1024 RGBA 母图，外围透明。
- `AppIcon.icns`：使用 Apple `iconutil` 封装，包含 16、32、128、256、512 点的 1x 和 2x 表示。
- 重建命令：`./macOS/build-icon.sh`。应用打包脚本 `./macOS/build-mac.sh` 会复制 ICNS 到应用资源目录。
- 这是兼容现有 AppKit 应用的静态 ICNS，不是 Icon Composer 的动态分层图标。

使用内置 imagegen 生成画面；生成工具未返回 Alpha 通道，因此封装时使用 Core Graphics 按连续圆角轮廓裁切背景，并缩放为标准母图尺寸。

生成提示词：

Use case: logo-brand. Create one production-ready macOS application icon for a quota dashboard utility showing two remaining-usage windows (5 hours and 7 days). 1024x1024 square PNG, genuinely transparent background outside the icon. Native macOS app icon aesthetic: centered continuous-curvature rounded-square tile occupying about 82% of canvas width, equal generous transparent margins, front-facing orthographic, gentle soft shadow wholly inside canvas. Refined pale ice-blue frosted-glass tile with restrained blue-violet edge tint and subtle top-left lighting. Main symbol: a large bold elegant gauge with TWO nested thick circular progress arcs, outer cobalt-blue arc and inner violet arc, both with rounded ends, both sharing a clean gap at the bottom; a simple white/silver short gauge needle pointing upper-right from a small central hub. High contrast, exceptionally simple silhouette, comfortably readable at 16 pixels. Subtle embossed depth, polished Apple desktop utility feel, no busy highlights. No text, numbers, letters, logo knots, badges, extra objects, decorative stars, mockup, border frame, or watermark. Deliver only the single isolated icon, no presentation sheet. True alpha transparency, not a painted checkerboard.
