# T-Dash 高德悬浮仪表 · iOS rootless

这是 T-Dash 仪表功能的原生 iOS 移植：使用 Tesla BLE 真实车速、挡位和电量，叠加在高德地图上。不是 Android APK 转包，不包含 GPS 伪装车速，也不是原 Android 全功能 App（车辆控制、天气、轨迹及工具箱未移植）。

## 安装

1. 需要 iOS 15 或更高版本的 **rootless 越狱**，并启用高德地图的 tweak 注入；典型环境为 Dopamine + ElleKit。不是 TrollStore 安装包，也不是 RootHide 包。
2. 安装 Release 中的 `com.caun.tdash.amap_0.1.0_iphoneos-arm64.deb`，在 Sileo / Zebra 或终端 `dpkg -i <文件>` 安装。
3. 完全退出高德再重新打开；若注入器要求，按包管理器提示重新加载用户空间。
4. 浮窗右上角打开设置，填写车辆 17 位 VIN，点「连接车辆」，允许高德使用蓝牙。
5. 首次使用点「添加蓝牙钥匙」，在停车状态下按车机提示刷实体钥匙卡并确认。沿用 T-Dash 的 Owner 级钥匙配对方式；插件只发送遥测读取请求。

私钥保存在高德进程所属的本机 Keychain，VIN 和布局保存在独立 defaults suite。无需 Tesla 账号或服务器。卸载插件不会自动删除车机钥匙；不用时可在车机钥匙列表中移除。删除/重装高德可能影响插件设置和钥匙访问，不保证保留配对。

## 横屏优先的透明仪表

- 横屏：316 × 110 pt 扁长仪表条，默认右下；突出车速、挡位、电量。
- 竖屏：226 × 150 pt 紧凑卡片，默认右侧中下部。
- 双击：112 × 66 pt 迷你速度表，再次双击展开。
- 拖动：横屏和竖屏各自保存位置；旋转与屏幕尺寸变化时限制在安全区内。
- 长按或点设置按钮：VIN、连接、配对、0–80% 底色不透明度、重置行程。数字不随底色变淡。
- 除仪表矩形和打开的设置页外，触摸穿透至高德。不会改变高德的旋转策略；高德导航进入横屏时浮窗随场景调整。

## 数据口径

- 速度来自车辆 DRIVE 数据，mph × 1.609344，取整显示；挡位同源。每个字段独立时间戳，超过 3 秒显示「—」。
- 每次请求仅一种数据类别，避免原项目已验证的多类别响应超出 MTU 问题。
- 电量仅在新鲜 P/N 挡、低速时单独读取，优先保证行驶中的速度刷新。超过 45 秒显示 `*`，标注「上次驻车电量」，**不是当前实时电量**；断开连接即清空。
- 本次里程 `≈` 为有效蓝牙车速积分估算，时长为有效采样时长；间隔超过 3 秒、后台、断联不补算。不是车辆里程计差，也不保存完整行程历史。
- 在高德前台工作，后台停连；回到前台会恢复本次已手动发起的连接。首次启动不自动扫描，不自动配对。
- 只接受通过 HMAC 握手及 AES-GCM 认证的遥测响应，不回退未加密旧固件响应。

## 注入配置证据

用户提供的 `com.jibamao.gaodeclean_0.9.110+trial71_iphoneos-arm64.deb`（SHA-256 `9bff57e96db28962c6e089878eb8e8d8900b4a3771805d463cd746c3075e8b59`）具有：

- 安装路径 `/var/jb/Library/MobileSubstrate/DynamicLibraries/`。
- `Architecture: iphoneos-arm64`；依赖 `firmware (>= 15.0), mobilesubstrate`。
- 二进制 plist 的 `Filter.Bundles = ["com.autonavi.amap"]`。REA 解析证据 `ev_1e28d443cebe5c3ef977bd67c3620475d96a3ed94dff048a75c881eb91475585`。

本插件复用以上加载路径与进程过滤方式，独立实现启动和界面，不复制或重新发布参考包的 dylib。未证明复用了参考包内部 UI hook；本插件无需 hook 高德私有类，通过 dylib initializer、UIKit 场景和生命周期通知创建透明窗口。参考包本身不提交仓库、不纳入 Release。

Rootless 路径与架构依据：[Theos rootless 文档](https://theos.dev/docs/rootless)。

## 构建与验证

GitHub Actions 工作流 `Build iOS rootless DEB`：macOS + Xcode，编译 arm64/arm64e 双架构、Apple codesign ad-hoc 签名、dpkg 打包。`workflow_dispatch` 输入版本号。

```sh
bash ios/scripts/test.sh
TDASH_VERSION=0.1.0 bash ios/scripts/build.sh
```

本机编译需完整 Xcode 和 `dpkg`。输出 `ios/packages/`。构建脚本会检查实际 DEB 的安装路径、架构、Bundle 过滤、Mach-O 初始化入口、依赖和所有架构的签名；协议测试覆盖官方加密向量、模拟车端会话、篡改/重放/坏包、分片和行程断流。

**验证边界：未接入用户的越狱手机与 Tesla 实车，因此无法宣称已实机注入成功、完成车机配对或验证具体车型/固件。** 当前高德版本必须包含 `NSBluetoothAlwaysUsageDescription`；缺少时插件提示原因并拒绝启动蓝牙，避免宿主因隐私声明缺失崩溃。不能由 DEB 修改 App Store 高德签名内的 Info.plist 来补齐权限。

保留根目录 Apache-2.0 `LICENSE`、`NOTICE`。协议字段依据仓库中的 Tesla 开源 `.proto`，iOS 实现为 Swift / CryptoKit / CoreBluetooth 移植。
