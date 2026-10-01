# GHUBSwitcher · G HUB 双版本便携切换器

在 Windows 上切换已安装的新版 G HUB 与 **2021.3**，分别保留两版的最新配置。离开某一版本前，工具先停止 G HUB，让数据库完成写入，再保存该版本的程序、配置和用户注册表数据；切回来时使用上次离开时保存的状态。

完整解压 ZIP 到你选定的文件夹，例如 `D:\GHUBSwitcher`。工具程序副本、两套环境存档、配置备份和运行记录全部保存在**解压目录的 `Data` 文件夹**，不会部署到 `%ProgramData%\GHUBSwitcher`。选择“新版备份”后，备份位于 `Data\Backups\modern-时间标识`。

首次使用必须在本机准备两套环境。ZIP 不包含别人的配置；准备完成后，`Data` 才是你的本机存档。活动 G HUB 仍使用 Logitech 的正常程序和配置路径，切换器不改变官方软件的安装位置。

## 功能

- 新版与 2021.3 分别保存程序和配置，新增、修改、删除的配置随对应版本保留。
- 首次准备新版备份，使用官方安装界面安装并捕获旧版，然后恢复新版。
- 由用户操作官方新版更新，工具随后登记更新后的程序和配置。
- 切换事务有持久日志、目录交换、失败回滚和恢复入口。
- 支持将便携目录放在另一块本地磁盘：跨盘先复制、校验文件与权限，再交换目录；失败时可续接或回滚。
- 自动识别当前 Windows 账户与配置目录；支持本地/域账户和具有本机用户配置的 Entra 账户。
- 部署前校验必需文件、SHA-256 清单、旧版安装器的 Logitech 签名及 2021.3 版本，使用受保护目录保存运行数据。

默认按**程序安装完整、配置恢复和 G HUB 实际启动**确认结果，不以系统驱动状态或重启作为切换门槛。首次备份仍会保存设备和服务元数据，默认模式不强制导出系统驱动包；空 INF、系统自带驱动或卸载后的残留设备不会阻止程序与配置捕获。严格技术模式继续要求驱动包可导出。

## 环境要求

- Windows 10/11，64 位。
- Windows 自带的 Windows PowerShell 5.1 和 .NET Framework。
- 电脑上先安装官方新版 G HUB。
- 首次部署和切换需要管理员授权，G HUB 界面仍以原普通用户身份启动。
- 准备 2021.3 时需提供对应的官方 Logitech 安装器，首次安装可能需要联网。
- 解压到固定位置的本地 NTFS 磁盘，并预留完整备份及目录复制所需的空间。网络目录、目录联接与符号链接不受支持。

不需要 Python 或 PowerShell 7。本项目是独立工具，与 Logitech 没有隶属关系。

## 从源码构建

```powershell
git clone https://github.com/ambitiouskain/GHUBSwitcher.git
cd GHUBSwitcher

# 编译本机操作库和启动 EXE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\Build-Native.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\Build-Launcher.ps1

# 完整回归
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\Test.ps1

# 生成可分发目录。输出位置须与源码分开，且不存在或为空。
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\Build.ps1 `
  -Distribution `
  -LegacyInstallerPath C:\Installers\lghub_installer_2021.3.exe `
  -OutputDirectory D:\GHUBSwitcher-release

# 将整个目录压缩，交给使用者
Compress-Archive -LiteralPath D:\GHUBSwitcher-release -DestinationPath D:\GHUBSwitcher-Portable.zip
```

构建使用 Windows 自带的 .NET Framework x64 C# 编译器。旧版安装器必须通过 Logitech 签名和 `2021.3.*` 版本校验。本仓库只发布切换器源码与测试，**不包含 Logitech 的软件、安装器、驱动包或任何用户配置**。

## 开始使用

1. 完整解压发行 ZIP 到准备长期使用的位置，双击 `GHUBSwitcher.exe`，或使用包内的 `启动切换器.cmd`。不要只复制 EXE 或 CMD。
2. 首次启动自动请求管理员授权，在解压目录内创建 `Data`。
3. 在当前新版 G HUB 设置中关闭自动更新，选择 **5**，按向导准备新版备份。
4. 选择 **6**，按向导通过官方界面卸载新版、安装 2021.3 并关闭旧版自动更新。捕获完成后工具恢复新版。
5. 以后选择 **1** 启动新版、**2** 启动 2021.3。关闭菜单后 G HUB 继续运行。

首次安装包含需要本人确认的官方界面操作，不是静默安装。完整流程见 [使用说明](docs/操作说明.md)。

受管理期间会暂停官方登录启动入口，防止中断切换后启动不完整的环境。重新登录 Windows 后，从工具选择 1 或 2 启动 G HUB。便携版只登记以原普通用户运行的按需启动任务，不安装 SYSTEM 后台监控或开机恢复任务。发生中断时打开工具选择 3；选择 8 后恢复原有的官方启动设置。

| 选项 | 用途 |
|---|---|
| 1 | 启动新版 |
| 2 | 启动 2021.3 |
| 3 | 恢复新版或续接未完成操作 |
| 4 | 打开诊断目录 |
| 5 | 首次准备新版备份 |
| 6 | 首次安装并捕获旧版 |
| 7 | 维护更新新版 |
| 8 | 退出切换器管理，保留新版 |

## 更新新版

先切到新版，选择 **7**，按提示自行完成官方更新并关闭自动更新，再确认让工具登记更新后的环境。此流程保留旧版配置。绕过工具直接更新后，原文件清单可能失效，需要通过维护或恢复流程处理。

## 数据位置与卸载

运行数据全部位于 `解压目录\Data`：

| 目录 | 内容 |
|---|---|
| `App` | 受保护的工具程序副本 |
| `Environments` | 未活动版本的程序和配置 |
| `Backups` | 新版、旧版的恢复备份 |
| `State`、`Manifests`、`Transactions`、`Status` | 状态、清单、事务与诊断 |
| `DriverPackages`、`Installers` | 恢复元数据与旧版安装器副本 |
| `Rescue`、`RestoreStage` | 恢复时保留的配置与暂存数据 |

目录普通用户可读取，写入需管理员权限。当前活动 G HUB 仍位于官方安装与用户配置目录。跨盘交换会在对应目录旁临时创建 `.ghub-transfer-...` 目录，完成后清理；中断时保留用于恢复。

要完整卸载：先在新版状态选择 **8**，确认退出管理成功并能正常启动新版 G HUB，再删除解压目录。这会放弃旧版存档、恢复备份和切换状态；以后从 ZIP 再运行需要重新准备两套环境。

**准备后不要移动或重命名整个文件夹。** 存档绑定本机用户及所选路径，换路径会拒绝操作；需先选择 8 退出管理，再在新位置重新解压、准备。可将整个 `Data` 另行复制归档，但不能将它直接移到另一台电脑继续切换。

日常切换保存最新版本配置，**不是每次打开菜单都重新做完整备份**。两版配置不会自动合并，设备固件与板载设置由硬件共享。

## 验证范围

测试在 Windows PowerShell 5.1 x64 中执行，涵盖便携数据位置、跨盘往返、配置保留、失败回滚、首次捕获中断恢复、权限和目录锁。具体发布验收见 [验证与恢复](docs/acceptance.md)。此前在开发机器完成过真实 G HUB 新旧版往返；便携改动另做隔离部署与跨盘验证。

这些结果不代表所有电脑或所有鼠标功能已验收，未在第二台实体电脑完成整套往返。安装器审计是有限范围的前后对比，详情见 [审计范围](docs/installer-audit-scope.md)。发现异常时保留诊断结果，先使用恢复入口。

哈希清单用于文件完整性检查，不是发布者身份认证。生成的启动 EXE 没有商业代码签名。

## 源码结构

| 路径 | 内容 |
|---|---|
| `src/Modules` | 状态、盘点、存储、切换、初始化、更新与恢复 |
| `src/Native` | Windows 文件、服务和驱动接口的 C# 实现 |
| `src/Launcher` | EXE 入口 |
| `src/PackagePreflight.ps1` | 加载包内模块前的文件完整性校验 |
| `build` | 编译、打包和测试脚本 |
| `tests` | 隔离测试与少量 Windows 接口验证 |
| `tools/Pester/5.7.1` | 随源码提供的测试依赖 |

## 许可证

切换器源码以 [MIT License](LICENSE) 开源。随仓库提供的 Pester 5.7.1 保留其 **Apache-2.0** 许可证和原版权声明，见 [第三方说明](THIRD_PARTY_NOTICES.md)。Logitech 软件及安装器不属于本项目许可证范围。
