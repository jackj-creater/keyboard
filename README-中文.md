# SpotlightCandidateFix 0.2.3

适用环境：

- iOS 17.x
- Relaxin
- RootHide 架构
- 插件注入已开启
- 默认只注入 `SpringBoard`

## 这个版本做什么

这是候选栏命中与文字颜色修复版本：

1. 只检查 Spotlight/Search 场景中的视图。
2. 只处理类名或上层视图包含以下特征的区域：
   - Candidate
   - Prediction
   - Completion
   - Keyboard
   - TextInput
   - Expanded
3. 默认清除候选栏、展开按钮和展开面板的深黑背景。
4. Spotlight 未激活时，`UIView` Hook 会立即返回，不再扫描 SpringBoard 启动视图。
5. 类名匹配改用 C 字符串，避开崩溃日志中的 `NSString containsString:` 路径。
6. 监听文本框、文本视图和系统键盘显示状态，避免漏掉 Spotlight 输入状态。
7. 候选词文字和按钮改为白色，候选栏、展开按钮和展开面板的深色背景改为透明。

它不会主动修改微信、Safari、设置等普通 App 的键盘，因为过滤文件只加载到 SpringBoard。

## 调整颜色

打开 `Tweak.xm`，在最顶部找到：

```objc
static const NSInteger kSCFBackgroundMode = 0;
```

可选值：

- `0`：完全透明（默认）
- `1`：半透明黑
- `2`：纯黑

半透明黑的透明度：

```objc
static const CGFloat kSCFBlackAlpha = 0.30;
```

例如改成：

```objc
static const CGFloat kSCFBlackAlpha = 0.20;
```

会更透明。

## 在手机上编译

你需要先安装：

- Theos（必须是支持 RootHide 的版本）
- NewTerm
- Git
- GNU Make
- clang / toolchain
- iPhoneOS SDK

RootHide 官方说明，对于不直接访问越狱文件路径的简单 tweak，可使用：

```makefile
THEOS_PACKAGE_SCHEME = roothide
```

本工程已经设置完成。

假设工程位于：

```text
/var/mobile/SpotlightCandidateFix
```

在 NewTerm 执行：

```sh
cd /var/mobile/SpotlightCandidateFix
make clean
make package
```

编译成功后，deb 通常位于：

```text
packages/
```

安装：

```sh
sudo dpkg -i packages/*.deb
sbreload
```

若系统没有 `sudo`，可以尝试：

```sh
dpkg -i packages/*.deb
sbreload
```

也可以在 Filza 中点击 deb，通过 Sileo 安装。

## 测试步骤

1. 安装后执行 `sbreload`。
2. 桌面下拉打开 Spotlight。
3. 输入拼音。
4. 点击候选词栏右侧的向下箭头。
5. 查看黑色区域是否变成半透明黑。

## 卸载或异常恢复

若出现 SpringBoard 重启、界面异常或安全模式：

1. 进入 Sileo 卸载 `SpotlightCandidateFix`；
2. 或在安全模式下执行：

```sh
dpkg -r com.keyboard.spotlightcandidatefix
sbreload
```

本工程没有修改系统文件，卸载后即可恢复。

## 当前限制

iOS 17.1.1 的 Spotlight 和键盘候选区域使用私有 UIKit/TextInputUI 类，类名未公开。第一版采用严格的场景和尺寸过滤，但仍可能：

- 没有命中目标；
- 只修改右侧箭头，未修改展开面板；
- 被系统材质在后续布局中重新覆盖。

这些情况需要结合设备截图和崩溃日志继续调整。
