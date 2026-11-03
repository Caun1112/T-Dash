# T-Dash 高德悬浮仪表 · iOS rootless

这是 T-Dash 仪表功能的原生 iOS 移植：使用 Tesla BLE 真实车速、挡位和车辆续航，叠加在高德地图上。不是 Android APK 转包，不包含 GPS 伪装车速，也不是原 Android 全功能 App（车辆控制、天气、轨迹及工具箱未移植）。

## 安装

1. 需要 iOS 15 或更高版本的 **rootless 越狱**，并启用高德地图的 tweak 注入；典型环境为 Dopamine + ElleKit。不是 TrollStore 安装包，也不是 RootHide 包。
2. 安装 Release 中的 `com.caun.tdash.amap_0.1.3_iphoneos-arm64.deb`，在 Sileo / Zebra 或终端 `dpkg -i <文件>` 安装。
3. 完全退出高德再重新打开；若注入器要求，按包管理器提示重新加载用户空间。
4. 长按浮窗约 0.65 秒打开设置，填写车辆 17 位 VIN，点「连接车辆」，允许高德使用蓝牙。
5. 首次使用点「添加蓝牙钥匙」，在停车状态下按车机提示刷实体钥匙卡并确认。沿用 T-Dash 的 Owner 级钥匙配对方式；插件只发送遥测读取请求。

私钥保存在高德进程所属的本机 Keychain，VIN 和布局保存在独立 defaults suite。无需 Tesla 账号或服务器。卸载插件不会自动删除车机钥匙；不用时可在车机钥匙列表中移除。删除/重装高德可能影响插件设置和钥匙访问，不保证保留配对。

## 0.1.3 圆形仪表

落实已确认的深色圆盘方案：**顶部居中续航数字（km）→ 中央大号车速 → 独立 km/h → 底部挡位**。不绘制电池图标，不显示常驻按钮、品牌行或额外行程。

- 苹方-简 中黑体 `PingFangSC-Medium`；车速和单位分占不同高度区域，三位数留足宽度。
- 默认直径 156 pt，横屏位于右上，竖屏位于右侧上部；横竖屏分别保存位置，旋转时限制在安全区。圆盘外的四角也穿透触摸给高德。
- D 挡采用薄荷绿，R 挡采用琥珀色，P/N/未知挡位为低饱和灰色。细弧线只作挡位状态强调，不表示 AP 或电量比例。
- 长按 0.65 秒打开设置；快速三连点锁定/解锁。锁定时不能拖动，长按仍可用；状态会保存。
- 升级保留 VIN、车辆钥匙和锁定状态。圆形布局使用独立的位置及透明度设置，首次采用新的默认位置和 92% 深色底；底色仍可调 0–100%。
- 没有接入的 AP、盲区、胎压等功能不显示模拟提醒。高德导航转为横屏时仪表随场景调整。

## 数据口径

- 速度来自车辆 DRIVE，mph × 1.609344；挡位同源。各字段独立维护时间戳，超过 3 秒显示「—」。
- 续航来自 CHARGE 的 `battery_range`（proto 字段 111，float 英里），转换为公里；不使用行程距离、总里程或电量百分比推算。字段缺失或无效时显示「— km」。
- 每次请求仅一种类别，避免原项目已验证的多类别响应超 MTU 问题。为了优先保证行驶中的车速，CHARGE 只在新鲜 P/N 挡且低速时读取。
- 续航超过 45 秒显示 `km*`，代表上次驻车读数；详情在设置中说明。断开连接即清空，绝不把旧读数当实时读数。
- 前台工作、后台停连；回到前台恢复本次已手动发起的连接。首次启动不自动扫描、不自动配对。
- 只接受通过 HMAC 握手及 AES-GCM 认证的遥测，不回退未加密旧固件响应。

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
TDASH_VERSION=0.1.3 bash ios/scripts/build.sh
```

本机编译需完整 Xcode 和 `dpkg`。输出 `ios/packages/`。构建脚本会检查实际 DEB 的安装路径、架构、Bundle 过滤、Mach-O 初始化入口、依赖和所有架构的签名；协议测试覆盖官方加密向量、模拟车端会话、篡改/重放/坏包、分片和行程断流。

**验证边界：未接入用户的越狱手机与 Tesla 实车，因此无法宣称已实机注入成功、完成车机配对或验证具体车型/固件。** 当前高德版本必须包含 `NSBluetoothAlwaysUsageDescription`；缺少时插件提示原因并拒绝启动蓝牙，避免宿主因隐私声明缺失崩溃。不能由 DEB 修改 App Store 高德签名内的 Info.plist 来补齐权限。

保留根目录 Apache-2.0 `LICENSE`、`NOTICE`。协议字段依据仓库中的 Tesla 开源 `.proto`，iOS 实现为 Swift / CryptoKit / CoreBluetooth 移植。
