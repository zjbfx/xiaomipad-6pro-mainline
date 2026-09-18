# Fedora 支持（第一版）

[Xiaomi Pad 6 Pro (liuqin)](../README.zh-CN.md) 的 Fedora Workstation 移植。

> **状态：第一版，真机日常可用。** 首次安装、首启、GDM 登录、桌面、Wi-Fi、触摸，以及"开机画面
> 从第一帧就是横屏"已验收；声音、蓝牙、磁吸键盘、挂起恢复、USB OTG 尚未逐项验收。首启一路踩到的
> 坑（两个弱依赖包、装配丢掉的 setuid 位、dconf profile 指到 Ubuntu 路径）都已在根装配器与
> preflight 里修掉并前移（见下）。已知未解决：自动旋转指错方向（见 README 的加速度计一行）。
> 本文说明能做什么、还差什么、以及为什么这样切分。本文暂时只有中文；英文版随移植完成一起补。

已通过的构建结果（Fedora 44 x86_64 主机、aarch64 交叉构建）：

| 检查 | 结果 |
|---|---|
| 根文件树 | 27107 个文件，`rootfs.tar.gz` 684 MB |
| 首启 initramfs 准入镜像（`preflight`） | PASS（14 个 0755 + 15 个 0644 + 拓扑符号链接逐条核对） |
| ABL 符号并集 | 1781（与发布版一致） |
| 设备树 | `b3c2a500…` **与发布版逐字节相同** |
| boot.img | 50466816 B，`c6019708…` |
| 分发边界扫描 | 无 `-calr.bin`、无 `cirrus/`、无 WLAN MAC / 蓝牙地址、无 persist 传感器注册表 |

## 设计：什么复用、什么替换

引导链与发行版无关，因此**内核、设备树、boot 镜像组装、存储准入契约机制**全部原样复用，
安装器镜像也复用已发布的那份（只覆盖它内嵌的两个随构建年代绑定的文件）。
换掉的是两处 Ubuntu 形状的东西：**根文件系统的来源**，以及**设备层的打包方式**。

| 组件 | Ubuntu 版 | Fedora 版 |
|---|---|---|
| 根文件系统 | Canonical ISO + casper squashfs | `dnf --installroot --forcearch=aarch64` 装 Workstation |
| 设备层 | 5 个 `.deb`（apt/dpkg chroot 安装） | **文件树**直接安装（契约钉的是文件哈希，不是包数据库） |
| 显示管理器 | `gdm3` / `/usr/sbin/gdm3` | `gdm` / `/usr/sbin/gdm` |
| Snap 相关 | `liuqin-snap-root-admission`、snap 配置片段 | 整块不安装 |
| 安装器镜像 | 从 Ubuntu 根抽取工具链 | **复用已发布的 `installer.img`**，但它内嵌的两份**随构建年代绑定的文件由 bundle 覆盖**（见下） |

桌面本身取自官方 comps 环境组 `@workstation-product-environment`（Files、Terminal、Software、
Firefox、LibreOffice、文档与图片查看器…），再叠加本项目的显式包列表（设备层与准入门禁依赖的那些）。
两样都要：组定义负责"这确实是一部 Fedora Workstation"，显式列表负责门禁要的文件不随组定义漂移。
早期版本只装显式列表，产出的是"有 GNOME 外壳、没有 Workstation 应用"的空桌面 —— 装到真机上才发现，
所以新增应用时优先加进组，只有门禁/设备层依赖才进显式列表。

### 复用发布版 `installer.img` 的两个覆盖项

发布的 `installer.img` 里内嵌着**它自己那一版**的安装脚本和根契约。这两样都不是发行版中立的：
脚本里带着当时的准入检查，契约里钉着当时那份根的哈希。Fedora 根两样都对不上，安装会在最后两步被拒。

`install.py` 因此从**自己的 HTTP 服务**（设备本来就从这里取 `rootfs.tar.gz`）按 sha256 取回这两个文件，
再用它们执行安装：

| bundle 里的文件 | 作用 | 覆盖掉镜像里的 |
|---|---|---|
| `install-root.sh` | 安装脚本 | 无条件的 snap-confine `getcap` 检查（Fedora 无 snapd） |
| `native-root.contract` | 根契约（41 个 pin） | Ubuntu 时代的契约，与 Fedora 根有 5 个 pin 不同 |

镜像本身一个字节都不改（哈希与发布版一致），发行版差异全部留在可审计的仓库文件里。
**v2 项**：与其覆盖，不如按本仓库的树自己构建 `installer.img`（需要 Ubuntu 根来产出 installer runtime）。

### 准入检查同时接受两种命名

`initramfs/init` 的 native 门禁现在接受 `gdm3` **或** `gdm`、`gdm3.service` **或** `gdm.service`。
这样一份 initramfs 能同时放行两种根，且**已经真机验证过的 Ubuntu 路径语义完全不变**。
`gnome` 档案仍是 Ubuntu 专用，Fedora 根走 `native` 档案。

### 首启黑屏：两个被 `install_weak_deps=False` 丢掉的包

Fedora 把下面两个包只当**弱依赖**引入，而本项目的根装配刻意关闭弱依赖（可审计、可复现），
于是它们没有进根。表现是**平板黑屏、没有登录界面**，日志里只留下间接症状：

| 缺的东西 | 谁需要它 | 症状 |
|---|---|---|
| `/usr/bin/dbus-daemon` | GDM 的 Wayland 会话助手直接 exec 它来起**用户会话总线**（系统总线由 dbus-broker 提供，替代不了它） | `gdm-wayland-session: Unable to run session message bus` → `GdmDisplay: Session never registered, failing`，重试到 `maximum number of display failures reached` |
| `/usr/lib64/security/pam_systemd.so` | `system-auth` 里的 `-session optional pam_systemd.so`；它才是把会话注册进 logind、进而拉起用户 systemd 实例的东西 | 模块缺失时这行**静默**不加载：`/run/user/` 为空，会话总线上 `org.freedesktop.systemd1` 永远不存在，gnome-session 起不来 |

第二处尤其隐蔽：`dbus-daemon` 装好后第一条错误消失、日志看起来"更健康"了，但会话仍然在
`gnome-session` 启动那一步死掉，屏幕上还是黑屏。

两处都已修好并**前移**到构建期（宁可在主机上失败，也不要在平板上再演一次黑屏）：

1. `tools/build-liuqin-fedora-rootfs.sh` 的 `desktop_packages` 显式列出 `dbus-daemon` 与 `systemd-pam`。
2. 同文件的 `preflight` 断言这两个文件存在。

**诊断路径（供以后复用）**：黑屏时 `fastboot boot out/image/bundle/installer.img` 进 RAM 安装器拿 root shell，
`blockdev --setrw /dev/sda{,35}` 后挂载 `/dev/sda35` 到 `/mnt/install`，再 `chroot /mnt/install/native-root`
读 `journalctl`；把 `/etc/gdm/custom.conf` 里 `[debug]` 的 `Enable=true` 打开，GDM 才会打印具体分支错误
（默认只打最后那一句）。开机后要改设备上的东西，可用设备层的 USB 救援通道（见下）。

> 当前平板上这两个文件是**手工推进去的**（为了少刷一次机）。按上面的流程重新构建根并安装一遍，
> 它们就会由 RPM 正式安装，rpmdb 记录与 SELinux 标签都正确。

### 装完以后 `sudo` 不能用：装配时被静默丢掉的 setuid 位

症状出现在**装好之后**：桌面正常，但用户执行 `sudo` 时提示的不是"不在 sudoers 里"，
而是 `sudo: effective uid is not 0, is /usr/bin/sudo on a file system with the 'nosuid'
option set...`（或干脆认证通过却无法提权）。原因不在账号、也不在 `sudoers`：

`stage_copy` 用 `cp -a` 把发行版根复制进镜像树。**`cp -a` 只有在复制进程真的具备
`CAP_FSETID` 时才保留 setuid/setgid 位**，不具备时它会一声不响地把这些位抹掉 —— 而
其余权限位（包括 sticky）原样保留。表现是整棵树 16 个特权文件全部变成普通权限：

| 文件 | RPM 装出来的 | 复制后 |
|---|---|---|
| `/usr/bin/sudo` | `4111` | `0111` |
| `/usr/bin/passwd`、`su`、`pkexec`、`mount`、`umount` | `4755` | `0755` |
| `/usr/lib/polkit-1/polkit-agent-helper-1` | `4755` | `0755` |

连带的：`pkexec` 失效 ⇒ 设置面板里的管理员授权弹窗全部失败；`unix_chkpwd`/`passwd`
失效 ⇒ 改密码、PAM 认证异常。内核、桌面、网络都不受影响，所以这个坑要到用户第一次
`sudo` 才暴露。

已修在构建期（同样前移）：

1. `tools/build-liuqin-fedora-native-root.sh` 的 `copy` 阶段：复制后按源树的
   `find -perm /6000` 清单**重放**这些位（源树是 RPM 装的，权威），并留下
   `privileged.map` 供后续核对。
2. 同文件 `preflight`：断言 `/usr/bin/sudo` 是 `4111`、`passwd`/`su`/`pkexec` 等是 `4755`，
   并核对特权文件总数不少于源树 —— 少了就在主机上失败。

**已经装好、但树是旧的平板怎么修**（不用重装、不动 userdata）：进 RAM 安装器，
`blockdev --setrw /dev/disk/by-partlabel/userdata` 后把它挂到 `/mnt/install`，
再对 `/mnt/install/native-root` 按清单逐个 `chmod`。清单的来源是**发行版根**（它是对的）：

```sh
find out/fedora-rootfs/rootfs -perm /6000 -printf '%m %P\n'   # 16 行，形如 "4111 usr/bin/sudo"
```

### 登录屏变成"没人能解锁的桌面"：dconf profile 指到了 Ubuntu 路径

症状：平板起来后看到的是**一个桌面**而不是登录界面 —— 活动概览能打开终端和设置面板，
顶栏里显示的用户是 `GDM Greeter`。看起来像"某个会话没被解锁"，其实是 gnome-shell
**根本没画登录屏**。

机制：gnome-shell 只在 `org/gnome/desktop/session/session-name` 等于 `gnome-login` 时
才进入登录屏形态，而这个值来自 GDM 的 `/usr/share/gdm/greeter-dconf-defaults`
（同一份文件还带着 greeter 的全部 lockdown 键：`disable-application-handlers`、
`disable-command-line`、`disable-save-to-disk` …）。greeter 读不到它，就渲染成一个
**没有任何锁定的普通桌面** —— 于是"终端能开、但没法解锁"。

读不到的原因在设备层：overlay 里的 `/etc/dconf/profile/gdm` 是照 Ubuntu 写的。它的注释
假设"打包版 profile 只叠了 user-db:user 和 file-db"，因此补了个 `system-db:gdm`；但
**Fedora 的打包版本来就叠了 `system-db:gdm` 与 local/site/distro**，并把 `file-db:` 指向
`/usr/share/gdm/greeter-dconf-defaults`。overlay 那份把整个 profile 覆盖掉，`file-db:`
指向 `/var/lib/gdm3/greeter-dconf-defaults` —— Fedora 上没有这个路径，greeter 的默认值
因此全部落空。Ubuntu 侧那份覆盖是必要的（它的打包版确实只有那两行），Fedora 侧只剩坏处。

已修在构建期（同样前移）：

1. `tools/build-liuqin-fedora-native-root.sh` 的 device 阶段：拷完 overlay 后**删掉**
   `/etc/dconf/profile/gdm`，让发行版自己的 profile 生效；并断言打包版里
   `system-db:gdm`（电源键委派要靠它）与 `file-db:` 那两行仍在。
2. 同文件 `preflight`：独立复核"覆盖不存在"与"`file-db:` 指向发行版路径" ——
   单独重跑 device 阶段也盖不住。

**已经装好、树是旧的平板怎么修**（不用重装、不动 userdata）：

```sh
sudo rm -f /etc/dconf/profile/gdm
sudo systemctl restart gdm
```

profile 只在会话启动时读一次，所以必须重启 GDM 才会出现登录屏。

### 任何"要建用户/组"的包都装不上：`/etc/gshadow` 里混进了 shadow 格式的行

症状出现在装 Workstation 环境组时，而且**反复重跑都失败**：

```
>>> Failed to add existing group "fastrpc" to temporary gshadow file: Invalid argument
>>> [RPM] %sysusers(avahi-…) scriptlet failed, exit status 1
Transaction failed: Rpm transaction failed.
```

任何带 `%sysusers` 脚本的包（avahi、tcpdump…）都会挂，于是整个事务被判定失败 —— 哪怕包的文件
早已落盘。根因在构建器：装 `fastrpc` 账号时，把 `/etc/shadow` 格式的九字段行**照抄进了
`/etc/gshadow`**（原文见 `tools/build-liuqin-fedora-rootfs.sh` 的账号段）：

| 文件 | 格式 | 该写什么 |
|---|---|---|
| `/etc/shadow` | `name:passwd:lastchange:min:max:warn:inactive:expire:reserved` | `fastrpc:!*:20000:0:99999:7:::` |
| `/etc/gshadow` | `name:passwd:admins:members` | `fastrpc:!::` |

`/etc/gshadow` 拿到九字段行后解析失败，之后**每一次**读该文件的 `%sysusers` 都报
`Invalid argument`。同一处的 `2>/dev/null || true` 还把这个写入错误盖住了。

已修在构建期：gshadow 改成四字段行，并去掉掩盖错误的 `|| true`（写不进就应当失败）。

**已经装好、树是旧的平板怎么修**：

```sh
sudo cp -a /etc/gshadow /root/gshadow.bak
sudo sed -i 's|^fastrpc:.*|fastrpc:!::|' /etc/gshadow
sudo dnf group install -y workstation-product-environment    # 现在能过
```

如果 dnf 还报 `Pending offline transaction has been invalidated`（指向 dnf5daemon），说明有残留的
离线事务，先 `sudo dnf5 offline clean` 再重跑。

## 前置条件

构建主机（已在 **Fedora 44 x86_64** 上开发）：

```sh
sudo dnf install -y qemu-user-static gcc-aarch64-linux-gnu dtc ccache \
  bc bison flex openssl-devel elfutils-libelf-devel cpio zstd rsync
```

必需的原厂输入（从你自己的原厂线刷包中提取 —— 项目不分发固件）：

- `FIRMWARE_POOL`：原厂固件池（首启 initramfs 读的那份）
- `FIRMWARE_TREE`：`build-liuqin-firmware-prep.sh` 产出的固件树；根装配器从它取 `usr/lib/firmware` 闭包
- `STOCK_OVERLAY_DIR` / `STOCK_BASE_DIR`：DTBO 条目与 vendor_boot DTB
- `AUDIO_TOPOLOGY`：编译好的 AudioReach 拓扑
- `WLAN_HSP2_TUPLE`：准备好的 WLAN 固件组合
- `SENSOR_STACK_TAR`：见下方"还差什么"
- `POWER_SETTINGS_BINARY`：**可选** —— 不提供则只警告，产出的平板能正常启动，只是设置面板里没有电源键策略项
- `MKBOOTIMG_DIR`：AOSP mkbootimg 脚本（`tools/fetch-aosp-mkbootimg.sh`）
- `INSTALLER_IMG`：已发布安装包里的 `installer.img`

## 构建

```sh
# 1. Fedora 根（在本机交叉构建 aarch64，不需要 aarch64 硬件）
sudo OUT_DIR="$PWD/out/fedora-rootfs" sh tools/build-liuqin-fedora-rootfs.sh all

# 2. 内核层（复用已发布内核，不再重新编译）
RELEASE_DIR=~/project/miPad6pro/liuqin-v0.2.0 sh tools/import-liuqin-release-kernel.sh
#    产出 out/kernel-from-release/：Image、模块树、DTB、build-info.json、SHA256SUMS

# 3. 输入清单：照 tools/fedora-inputs.example.json 填一份到 tools/local/fedora-inputs.json

# 4. 设备层装配 → boot.img → bundle（每阶段单独可重跑，全部需要 root）
for s in copy device assemble preflight manifest pack boot bundle; do
  sudo python3 tools/build-liuqin-image.py --inputs tools/local/fedora-inputs.json \
    --kernel-out out/kernel-from-release --out out/image --distro fedora --stage "$s" || break
done
```

产物在 `out/image/bundle/`：`boot.img`、复用的 `installer.img`、`rootfs.tar.gz`、`install.py` 与清单文件。

`--distro fedora` 走的是与 Ubuntu 完全相同的组装入口：脚本、内核、DTB、boot 镜像组装、契约机制全部共用，
只有两个发行版形状的东西不同 —— 根从哪来（`FEDORA_ROOTFS_ROOT`）、设备层怎么装（文件树而非 `.deb`）。
整条链 fail-closed：缺任何一个输入就拒绝装配，而不是产出一个平板会拒绝的根。

### 主机侧验证（上机之前）

```sh
sh tools/build-liuqin-fedora-rootfs.sh preflight    # 发行版侧：gdm、符号链接、systemd 可执行
sh tools/build-liuqin-fedora-native-root.sh preflight  # 设备层侧：14 个 0755 + 15 个 0644 + 拓扑链接
sh tests/persistent-root.sh                          # 准入机制的 fail-closed 测试
```

`preflight` 是 `initramfs/init` 里 native 门禁的镜像 —— 在主机上失败只花几秒，在平板上失败要经历一轮启动循环加救援 shell。

## 真机安装

与 Ubuntu 版流程相同，外加两个**必须做**的手工步骤（发布包与 ABL 的已知问题）：

1. **关闭 vbmeta 校验**（否则 ABL 拒绝启动未签名的 boot 镜像，开机直接跳 fastboot）
2. **启用 `liuqin-hide-gunyah-node.service`**（否则 `systemd-detect-virt` 报 `vm-other`，GSD 走 VM 路径导致电源键立即关机）

详见 [安装步骤](INSTALL-TESTING.zh-CN.md) 与 [安装指南](FLASHING.zh-CN.md)。

## 还差什么

设备层里有三类东西，Fedora 侧只有第三类需要额外工作：

| 类别 | 内容 | 状态 |
|---|---|---|
| 与发行版无关 | systemd 单元、固件、电源键/亮度守护进程、dconf 锁、UCm2 | ✅ 已由装配器安装 |
| 项目自建、装在 `/usr/local` | 传感器代理链路、辅助脚本 | ✅ 已由装配器安装（需要 `SENSOR_STACK_TAR` 输入） |
| **修改发行版自带软件** | 打过补丁的 `gnome-control-center`、覆盖 `iio-sensor-proxy` | ⬜ **待移植** |

第三类里：

1. **传感器栈（准入硬门槛）** —— ✅ **已参数化**：`tools/build-liuqin-sensors-stack.sh` 现在支持
   `LIUQIN_SENSOR_DISTRO=fedora`，在 Fedora 根的可写 overlay 上编译同样的三个上游组件
   （libssc / iio-sensor-proxy / hexagonrpc），差异只在构建环境：
   dnf 依赖（含 `cargo rust`，Ubuntu 桌面根自带而 Fedora 需要显式装）、`/usr/lib64`、
   Python 的 `site-packages` 布局、以及不搬运 Ubuntu 特有的 libqrtr 运行时。
   ✅ **已用真实构建验证**（`out/liuqin-sensors-stack-fedora/artifacts/sensor-stack.tar`），
   装配进根后 `preflight` 通过：门禁要的 `/usr/libexec/iio-sensor-proxy`、`/usr/bin/hexagonrpcd`
   都在位。
   安装时的每机数据供给（`provision-liuqin-from-persist.sh` 把校准/MAC/蓝牙地址/传感器注册表
   写进已安装的根）依赖 `fastrpc` 用户 —— Fedora 根的 `/etc/passwd` 里已有 `fastrpc`（uid 2907），
   该步骤的落位路径与 Ubuntu 根一致。
2. **BusyBox** —— ✅ 已解决（用 Fedora 自带的包，不需要外部静态构建）。
3. **改过电源面板的 gnome-control-center** —— ⬜ 未移植，但**不是准入门槛**（门禁里没有它），
   只影响设置面板里那个电源键策略项。可以作为 v2 项。
4. **Snap 遗留文件（清理项，不影响启动）** —— 设备层里还带着 `liuqin-snap-root-admission`
   脚本与其 unit。Fedora 没有 snapd，它**没有被链进 `basic.target`**（`assemble` 阶段会拒绝
   那种情况），所以只是 Ubuntu 形状的死代码，v2 从设备层删掉即可。

准入门禁要求的 `/usr/libexec/iio-sensor-proxy` 和 `/usr/bin/hexagonrpcd` 由第 1 项提供；
在它验证通过之前，Fedora 装配器产出的根会被准入拒绝 —— 这是刻意的：宁可在主机上失败。

## 已知问题（与发行版无关）

- **SLPI（传感器 DSP）上电会触发硬件级切电**，出现在较老的原厂固件上（如 V14.0.9.0 / Android 13）。
  表现是 GNOME 起来约 30 秒后静默断电。临时对策是断开图形会话里的传感器入口：
  ```sh
  sudo rm -f /etc/systemd/user/graphical-session.target.wants/liuqin-sensor-proxy-session-refresh.service
  ```
  升级到较新的原厂固件后应重新验证。
