# intel-mac-optimizer

一套给 **2019 款 16 寸 MacBook Pro（Intel i9 + 双显卡）** 做的本地优化，用来延长老款 Intel Mac 的使用寿命。包括三个部分：

| 组件 | 作用 |
| :--- | :--- |
| **AutoGPU**（菜单栏 app） | 综合多路温度控制双风扇；在核显 / 独显之间自动切换；视频会议时降噪；系统过热时强制满速 |
| **smc-fan-helper**（root 小工具） | 替 AutoGPU 写风扇寄存器，并带一个看门狗：AutoGPU 停止响应 10 秒后，把风扇交还给系统 |
| **mac27-prewarmer**（预热器） | 把常用程序、系统库和字体提前读进内存缓存，让打开应用更快 |

另外还有一项内核参数：把 `kern.maxvnodes` 提高到 1,000,000，让大内存机器能缓存更多文件。

> ⚠️ **只在下面这台机器上实测过。** 其他机型可以参考思路，但不要直接安装，先看下面的 [移植到其他 Mac](#移植到其他-mac)。**Apple Silicon（M 系列）完全不适用。**

## 测试机器

- MacBookPro16,1（2019 款 16 寸），i9-9880H，Intel UHD 630 + AMD Radeon Pro 5500M，64 GB DDR4
- macOS 26.6（最后一个支持 Intel 的版本）

## 实测效果

- **预热器**：
  - 内存缓存里常驻约 12.3 GB：系统共享库 5.4 GB、应用代码 3.0 GB、命令行工具 1.7 GB、字体 0.8 GB，以及其他内容，实测全部在内存里。
  - 全量扫描约 20 秒，日常补齐约 2.4 秒。
  - 这部分内存是系统可以随时回收的缓存，不会引起内存交换。
- **显卡**：
  - 平时用核显，独显休眠时只耗约 0.08 W。
  - 核显负载连续约 5 秒达到 55% 时切到独显；独显闲下来后再切回核显，并带防反复切换的保持时间。
- **风扇**：16 线程满载时，风扇比 macOS 默认策略更早升速；系统报告过热时直接满速。

## AutoGPU 详解

**风扇策略。** 综合以下传感器计算目标转速：
- CPU 温度 `TCXC`、独显温度 `TG0P`；
- 两根热管 `Th1H`、`Th2H`，掌托 `Ts0P`；
- 左右雷电口 `TTLD`、`TTRD`；
- 功耗 `PG0R`、`PSTR`。

转速调整有几条规则：
- 有升降速步长限制和死区，避免来回抖动；
- 单次温度尖峰会先提前加速；
- 达到紧急温度加 5°C 时直接满速。

另外还有两层保护：
- **系统过热保护**：读取 `NSProcessInfo.thermalState` 和 `CPU_Speed_Limit`。达到 Serious 级别、或 CPU 被系统降频时，风扇满速；达到 Fair 级别时，风扇不低于 25%。
- **会议模式**：通过 CoreAudio 找出正在使用麦克风的进程。如果它是会议或通话软件，就调高风扇的起转温度，让风扇更安静，同时让显卡尽量留在核显上。

**显卡切换。** 通过 `AppleMuxControl` 切换，选择器 2 用来设置、选择器 3 用来读取，读回 0 表示独显、非 0 表示核显。切换规则：
- **切到独显**，满足任一条件即可：
  - 核显占用（IOAccelerator 的 `Device Utilization %`）连续 2 次达到 55%（会议中是 82%、连续 4 次）；
  - Chrome 当前网址在 3D 网站名单里；
  - 接了外接显示器。
- **切回核显**：要同时满足三个条件：
  - 连续约 15 秒没有需要独显的理由；
  - 独显功耗低于 28 W；
  - 本次保持时间已过。

  保持时间第一次是 60 秒；如果切回后 2 分钟内又被拉回独显，就翻倍，最长 15 分钟。
- 屏幕休眠时不做任何切换；唤醒后 30 秒内不触发负载切换。

**看门狗。** AutoGPU 每 2.5 秒写一次心跳文件 `/tmp/autogpu.heartbeat`。smc-fan-helper 接管风扇后会派生一个 root 看门狗：心跳超过 10 秒没更新，就把风扇恢复成系统自动控制。这样即使 AutoGPU 崩溃，风扇也不会卡在低转速。

**可调参数。** 都通过 `defaults write com.ericzhu.autogpu <键> <值>` 修改，大约 30 秒内自动生效：

| 键 | 默认值 | 含义 |
| :--- | :--- | :--- |
| `StartTempIGPU` / `StartTempDGPU` / `StartTempMeeting` | 61.5 / 57.5 / 63.5 | 风扇开始升速的温度（°C） |
| `MidTempIGPU` / `MidTempDGPU` / `MidTempMeeting` | 74 / 71 / 76 | 中段温度 |
| `FullTemp` / `EmergencyTemp` | 86 / 88 | 满速温度、紧急温度 |
| `MaxStepUpRPM` / `MaxStepDownRPM` / `DeadbandRPM` | 800 / 170 / 55 | 每次升速、降速的上限，以及不调整的范围 |
| `DGPUSustainWatts` | 28 | 独显功耗高于这个值时留在独显 |
| `OSThermalGuard` / `OSThermalFairFloorRatio` | YES / 0.25 | 系统过热保护开关；Fair 级别下的最低转速比例 |
| `HeavyWebGLDomains` | threejs.org、sketchfab.com、shadertoy.com、figma.com/file 等 | 打开这些网站时直接用独显 |
| `MeetingBundleIDs` | 腾讯会议、Zoom | 额外的会议软件（微信、FaceTime、Teams、Slack、飞书已内置） |

菜单栏可以切换风扇模式（智能温控 / 苹果原厂）和显卡模式（智能 / 锁定核显 / 锁定独显）。

## 预热器详解

**会预热：**
- x86_64 的程序代码。通用二进制只读 Intel 部分，Apple 芯片的代码直接跳过，本机省了约 3.2 GB；
- 界面资源：`.car`、`.pak`、`.metallib`、`.nib`、`.bin`、`.dat`；
- 字体：`.ttf`、`.ttc`、`.otf`；
- 系统共享库缓存。

**工作方式。** 先用 `mincore()` 检查哪些部分已经在内存里，只读缺的部分。
- **全量扫描**：每 24 小时最多一次，或在配置文件改动后、带 `--full` 参数运行时进行。扫描时把预热过的文件和区间记进清单 `~/Library/Caches/com.ericzhu.mac27prewarmer/manifest.tsv`。
- **按清单补齐**：其余时候只按清单补齐。如果清单里超过 2% 的文件已经不存在，就重新做一次全量扫描。

**配置文件** `~/.config/mac27-prewarmer.conf`（不存在时会自动生成默认配置）：

```
include <目录>     额外扫描这个目录（系统库缓存、/Applications、/System/Applications 始终扫描）
exclude <文字>     跳过路径里包含这段文字的文件或文件夹，例如 exclude /Keynote.app/
```

改完配置后，运行 `~/.local/bin/mac27-prewarmer --full` 立即生效。

**预热多少合适**：参考可用内存的 20%。12 GB 是按 64 GB 内存设置的；16 GB 内存的机器建议去掉大部分 include，再排除不常用的大应用。

## 构建与安装

需要 Xcode 命令行工具（`xcode-select --install`）。

```bash
./build.sh
```

安装（会用到 sudo）：

```bash
# 1. AutoGPU
cp -R build/AutoGPU.app /Applications/
cp launchd/com.ericzhu.autogpu.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ericzhu.autogpu.plist

# 2. 风扇 helper：必须是 root 所有并带 setuid，AutoGPU 才会启用风扇控制
sudo install -o root -g wheel -m 4755 build/smc-fan-helper /usr/local/bin/smc-fan-helper

# 3. 预热器
mkdir -p ~/.local/bin ~/.config
cp build/mac27-prewarmer ~/.local/bin/
cp -n config/mac27-prewarmer.conf ~/.config/   # 按自己的机器修改
sed "s#__HOME__#$HOME#g" launchd/com.ericzhu.mac27prewarmer.plist > ~/Library/LaunchAgents/com.ericzhu.mac27prewarmer.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ericzhu.mac27prewarmer.plist

# 4. 提高 vnode 上限（每次开机生效）
sudo cp launchd/com.ericzhu.maxvnodes.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/com.ericzhu.maxvnodes.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.ericzhu.maxvnodes.plist
```

安装后需要确认几件事：
- **后台项目**：在「系统设置 → 通用 → 登录项与扩展」里允许这几个后台项目。如果被标成"不允许"，开机时它们不会运行。
- **Chrome 授权**：第一次读取 Chrome 网址时，macOS 会弹窗请求自动化权限，需要点允许，否则 3D 网站名单不会生效。
- **日志**：查看 `/tmp/autogpu.log`、`/tmp/mac27-prewarmer.log`。

**更新 AutoGPU**：重新 `./build.sh`，把 app 拷到 `/Applications/`，再运行 `launchctl kickstart -k gui/$(id -u)/com.ericzhu.autogpu`。

**卸载**：

```bash
launchctl bootout gui/$(id -u)/com.ericzhu.autogpu
launchctl bootout gui/$(id -u)/com.ericzhu.mac27prewarmer
sudo launchctl bootout system/com.ericzhu.maxvnodes
/usr/local/bin/smc-fan-helper auto   # 风扇交还系统
rm -rf /Applications/AutoGPU.app ~/.local/bin/mac27-prewarmer ~/Library/Caches/com.ericzhu.mac27prewarmer
rm ~/Library/LaunchAgents/com.ericzhu.{autogpu,mac27prewarmer}.plist
sudo rm /usr/local/bin/smc-fan-helper /Library/LaunchDaemons/com.ericzhu.maxvnodes.plist
```

## 移植到其他 Mac

按风险从高到低：

1. **风扇（SMC）**：
   - 风扇的最低和最高转速是运行时从 SMC 读取的（`F0Mn`/`F0Mx`/`F1Mn`/`F1Mx`），读不到时才用本机的 1836–5616 / 1700–5200 RPM 作为后备值。
   - **温度传感器的名字因机型而异。** 先用 SMC 读取工具确认 `TCXC`、`TG0P`、`Th1H`、`Ts0P`、`TTLD` 等在目标机型上存在，并且读数合理。传感器读错，风扇就会按错误的温度运行。
   - 单风扇的机型需要改代码。
2. **显卡切换**：只适用于带硬件切换器的双显卡 MacBook Pro（2010–2019 款 15/16 寸）。只有核显的机型（13 寸、Air、mini）要关掉这一部分，可以在菜单里锁定核显，或者删掉相关代码。
3. **温度阈值**：默认值是按 i9-9880H 的 16 寸调的。换 i7 或 15 寸机型，建议先保留默认值观察日志，再用 `defaults write` 微调。
4. **预热器**：按内存大小调整 include/exclude，见上文。
5. **标识符**：`com.ericzhu.*` 可以保留，也可以改。要改的话，`Info.plist` 的 bundle id、launchd plist 的 Label 和文件名、`defaults` 的域名，以及预热器源码里的缓存目录要一起改。

## 安全说明

- `smc-fan-helper` 是 setuid root 程序。本机任何用户都能用它设置风扇转速，不过转速会被限制在硬件允许的范围内，参数也做了严格检查。不需要风扇控制时可以不装。
- 写 SMC 有风险，风扇转速如果设得过低，机器可能过热。所以设计了两层保护：
  - 看门狗：AutoGPU 失联 10 秒后，把风扇交还系统；
  - 系统过热保护：macOS 报告过热时风扇满速。
- 本项目不修改系统文件，不需要关闭 SIP。

## 踩过的坑

- **网页毛玻璃特效会把核显打满。** 一个 `backdrop-filter: blur()` 卡片很多的监控页面，放着不动就占核显 13%，滚动时达到 90%，因此反复触发切换到独显。去掉模糊后降到 2%。要排查网页的显卡占用，可以开着页面，每秒用 `ioreg -r -d1 -c IntelAccelerator` 读一次 `Device Utilization %`，对比开和关的差别。
- **定时器要加到 `NSRunLoopCommonModes`。** 否则打开菜单栏菜单时定时器会停，风扇控制也会暂停。
- **屏幕休眠时切换器可能返回非 0、非 1 的状态值。** 只判断 0（独显）和非 0（核显），并且在屏幕休眠时跳过所有切换逻辑。
- 在 SIP 保护下，`launchctl disable` 对苹果自带的服务不起作用，重启后也不起作用。
- 后台项目被标为"不允许"时，LaunchDaemon 开机不会加载，命令行也不会报错。
