# SpotlightCandidateFix 0.1

适用环境：

- iOS 17.x
- Relaxin
- RootHide 架构
- 插件注入已开启
- 默认只注入 `SpringBoard`

## 这个版本做什么

这是第一版“修复 + 探测”版本：

1. 只检查 Spotlight/Search 场景中的视图。
2. 只处理类名或上层视图包含以下特征的区域：
   - Candidate
   - Prediction
   - Completion
   - Keyboard
   - TextInput
   - Expanded
3. 默认将深黑背景改为 30% 透明度的黑色。
4. 会输出 `[SCF]` 日志，方便第二版精确定位 iOS 17.1.1 的实际私有类名。

它不会主动修改微信、Safari、设置等普通 App 的键盘，因为过滤文件只加载到 SpringBoard。

## 调整颜色

打开 `Tweak.xm`，在最顶部找到：

```objc
static const NSInteger kSCFBackgroundMode = 1;
```

可选值：

- `0`：完全透明
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

## 查看日志

先尝试：

```sh
log stream --level debug --predicate 'eventMessage contains "[SCF]"'
```

如果 NewTerm 中没有输出，可尝试：

```sh
log show --last 5m --predicate 'eventMessage contains "[SCF]"'
```

将包含 `[SCF] matched class=...` 的日志复制出来，用于制作更精确的第二版。

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

这些情况需要根据 `[SCF]` 日志制作第二版。
