# 在 Windows 上构建小狼毫（weasel）

本文记录本仓库的完整构建流程，以及本机（VS 2022 Community）实际踩到的坑。
所有步骤均已验证通过。

---

## 0. 为什么不能在 Linux / WSL 上构建

小狼毫是纯 Win32 + TSF 项目，`WeaselTSF` / `WeaselServer` / `WeaselSetup` /
`WeaselDeployer` 依赖 `msctf.h`、ATL、COM 与 Windows SDK，并且需要 **MSVC 版**
的 `rime.lib` / `rime.dll`。没有任何 Linux 构建路径，也不存在交叉编译配置。
CI（`.github/workflows/ci.yml`）同样只在 `windows-2022` 上构建。

WSL 最多能用来跑 `plum/rime-install` 拉取 Rime 数据（`build.bat` 的 `:build_data`
步骤需要 `bash`），主编译必须回到 Windows。

---

## 1. 前置依赖

| 依赖 | 版本 | 说明 |
|---|---|---|
| Visual Studio 2022 | Community 可用 | 必须包含 **MSVC v143** 与 **C++ ATL** |
| C++ ATL 组件 | v143 | `Microsoft.VisualStudio.Component.VC.ATL`，**必须装** |
| C++ MFC 组件 | v143 | Community 版**不提供**，见第 5 节 |
| Boost | 1.84.0 | 只需头文件 + 5 个静态库，见第 4 节 |
| librime | 发行版预编译 | 由 `get-rime.ps1 -use dev` 下载，**无需源码编译** |
| NSIS | 3.x | 仅打包安装包时需要 |
| plum | 子模块 | 拉取 Rime 数据 |

检查 ATL 是否已安装：

```powershell
Get-ChildItem "$env:ProgramFiles\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC" `
  -Directory | ForEach-Object { Join-Path $_.FullName "atlmfc\include\atlbase.h" } |
  Where-Object { Test-Path $_ }
```

安装（会弹 UAC）：

```powershell
$a = 'modify --installPath "C:\Program Files\Microsoft Visual Studio\2022\Community" ' +
     '--add Microsoft.VisualStudio.Component.VC.ATL --quiet --norestart'
Start-Process "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vs_installer.exe" `
  -ArgumentList $a -Verb RunAs
```

> `Start-Process -ArgumentList` 传数组时，含空格的元素会被截断
> （报 `installPath: C:\Program`）。必须拼成**一个字符串**再传。

---

## 2. 准备依赖

```powershell
cd D:\GitHub\weasel

# Boost 头文件
#   https://archives.boost.io/release/1.84.0/source/boost_1_84_0.7z  (106 MB)
#   解压到 deps\boost_1_84_0

# librime 预编译库（x86 + x64 + opencc 数据）
git submodule update --init plum
$global:authorization = (gh auth token)   # 避免 GitHub API 匿名限流 403
.\get-rime.ps1 -use dev
#   产出 include\rime_*.h、lib\rime.lib、lib64\rime.lib、
#        output\rime.dll、output\Win32\rime.dll、output\data\opencc\

# env.bat
Copy-Item env.vs2022.bat env.bat -Force
#   确认 BOOST_ROOT 指向 deps\boost_1_84_0
```

`env.bat` 与 `deps/` 都在 `.gitignore` 中，不会污染仓库。

---

## 3. Rime 数据

```powershell
$env:PATH = "D:\Applications\Git\bin;$env:PATH"   # 避免命中 C:\Windows\System32\bash.exe（WSL 启动器）
$env:plum_dir = "plum"; $env:rime_dir = "output/data"
& "D:\Applications\Git\bin\bash.exe" plum/rime-install
```

产出 `output\data\` 下的 `essay.txt`、`default.yaml`、`luna_pinyin.*` 等。

---

## 4. Boost 静态库（**最大的坑**）

weasel 用到 `boost/archive`、`boost/serialization`、`boost/thread`，
这些通过 auto-link 拉入以下静态库：

```
libboost_serialization-vc143-mt-s-{x64|x32}-1_84.lib
libboost_wserialization-vc143-mt-s-{x64|x32}-1_84.lib
libboost_thread-vc143-mt-s-{x64|x32}-1_84.lib
libboost_system-vc143-mt-s-{x64|x32}-1_84.lib
libboost_chrono-vc143-mt-s-{x64|x32}-1_84.lib
libboost_atomic-vc143-mt-s-{x64|x32}-1_84.lib
```

> **注意是 `x32` 而不是 `x86`**：32 位时 boost 的
> `BOOST_LIB_ARCH_AND_MODEL_OPT` 为 `-x32`
> （`boost/config/auto_link.hpp:420`）。

### 为什么不能直接用 build.bat 的 `boost` 步骤

`build.bat` 会调用 `b2`，但 b2 在本机**完全无法工作**：

```
don't know how to make <p/D:/GitHub/weasel/deps/boost_1_84_0>C:\Program Files\...\bin\Hostx64\vcvarsall.bat
...skipped <...>msvc-setup.nup for lack of ...
```

原因链条：

1. `msvc.jam` 的 `locate-default-setup()` 用 `GLOB` 在编译器所在目录
   （`...\bin\Hostx64\`）找 `vcvarsall.bat`，但该文件实际位于
   `VC\Auxiliary\Build\`；
2. 找不到后回退到 `setup ?= [ path.join $(parent) "vcvarsall.bat" ]`；
3. jam 的 `path.join` 不把含空格的 `C:\Program Files\...` 识别为绝对路径，
   于是拼成 `<boost根目录>C:\Program Files\...`；
4. 引擎无法生成 `msvc-setup.nup`，于是所有目标被 skip。

`user-config.jam` 里写 `using msvc : 14.44 : D:/VS2022/.../cl.exe ;`
（`D:\VS2022` 为指向 VS 的 junction）也**无效**——自动探测仍会用真实路径。
CI 能通过是因为 `msvc-dev-cmd` 预先设好了环境；换言之本机这条路走不通，
不要再在 b2 上浪费时间。

### 可行做法：用 cl.exe 直接编译这 5 个库

只需约 60 个源文件，几分钟即可。关键点：

- 静态 CRT：`/MT`（对应库名里的 `-mt-s`）
- 必须 `BOOST_ALL_NO_LIB`，并按库加各自的 `BOOST_*_BUILD_LIB`
  （`tss_pe.cpp` 需要 `BOOST_THREAD_BUILD_LIB` 与 `BOOST_THREAD_WIN32`，
  否则会缺 `boost::tss_cleanup_implemented`）
- 源码清单照抄 `libs/serialization/build/Jamfile.v2`：
  `boost_serialization` = `SOURCES`；
  `boost_wserialization` = `SOURCES + WSOURCES + xml_oarchive + utf8_codecvt_facet`
- `extended_type_info_typeid` / `_no_rtti`、`stl_port` 内部有条件编译，
  一起编译即可（其中一个是空 TU）
- `libs/thread/src/win32` 下 `thread.cpp` + `tss_dll.cpp` + `tss_pe.cpp`
  三个都要（Jamfile 里 win32 sources 就是这三个）

脚本见 `scripts/build_boost_libs.ps1`（本仓库外，见第 8 节）。

---

## 5. afxres.h（第二个坑）

`WeaselTSF.rc` 与 `WeaselServer.rc` 带有 stock MFC 资源脚本模板，
其中 `#include "afxres.h"`。而 **`afxres.h` 属于 MFC 组件，VS Community 不提供**：

```
Warning: Cannot find package: Microsoft.VisualStudio.Component.VC.MFC in product graph.
```

好在这两个脚本实际只用到头文件里的两类东西：

- `AFX_RESOURCE_DLL` / `AFX_TARG_*` —— 全部只出现在 `#if !defined(...)` 守卫里，
  从不被取值；
- `LANG_ENGLISH` / `SUBLANG_ENGLISH_US` / `LANG_CHINESE` /
  `SUBLANG_CHINESE_SIMPLIFIED` / `SUBLANG_CHINESE_TRADITIONAL`。

后者用标准 Windows language ID 补齐即可，编译出的资源与真头文件完全一致。
仓库里已经放了一份 `include/afxres.h`（见第 8 节的注意事项）。

### 两个 rc.exe 的坑（写这个 shim 时踩到的）

1. `INCLUDE` 环境变量对 MSBuild 的 `ResourceCompile` **无效**。
   好在 `$(SolutionDir)\include` 本来就在 RC 的 include 路径里，
   所以把 shim 放进 `include/` 即可，无需改任何工程文件。
2. rc.exe 对注释与预处理指令的组合很敏感：
   - `/* ... */` 注释块后面跟任何预处理指令 → `RC1004 unexpected end of file`；
   - 注释里出现引号 / 反引号 / 撇号也会破坏词法分析。
   
   所以 shim 的**预处理指令必须全部放在前面，注释放最后，且不带引号**。

---

## 6. 构建

在 VS 开发者命令提示符（vcvars 已加载且 MSBuild 在 PATH）里：

```bat
build.bat weasel       :: 全解决方案 x64 + Win32
build.bat installer    :: 顺带重新构建并用 NSIS 打包
```

等价的显式调用（自动化脚本里用这个更稳）：

```bat
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
set "PATH=C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin;%PATH%"
cd /d D:\GitHub\weasel
build.bat installer
```

单独构建某个工程时**必须显式传 `SolutionDir`**，否则 `$(SolutionDir)` 为空，
会报 `Cannot open include file: 'WeaselIPC.h'` 之类的错误：

```bat
msbuild WeaselTSF\WeaselTSF.vcxproj /t:Build /p:Configuration=Release ^
        /p:Platform=x64 /p:SolutionDir=D:\GitHub\weasel\ /nr:false
```

### 产物布局（注意命名）

| 文件 | 架构 | 说明 |
|---|---|---|
| `output\weasel.dll` | x86 | **32 位** IME |
| `output\weaselx64.dll` | x64 | 64 位 IME，安装脚本在 x64 上重命名成 `weasel.dll` |
| `output\WeaselServer.exe` | x64 | |
| `output\Win32\WeaselServer.exe` | x86 | |
| `output\WeaselDeployer.exe` / `output\Win32\...` | x64 / x86 | 部署器 |
| `output\WeaselSetup.exe` | x86 | 安装/卸载 |
| `output\rime.dll` / `output\Win32\rime.dll` | x64 / x86 | 预编译，非本地构建 |
| `output\archives\weasel-*-installer.exe` | — | NSIS 安装包 |

`output\Win32\weasel.dll` **不存在**，这是正常的。

### 打包 NSIS 安装包

```powershell
winget install --id NSIS.NSIS --accept-package-agreements --accept-source-agreements
```

装到 `C:\Program Files (x86)\NSIS\Bin\makensis.exe`，即 `build.bat` 期望的路径。
SourceForge 直连在本网络被限流，`winget` 是可用的下载途径。

ARM 版未构建，`install.nsi` 里对应 `File /nonfatal`，只会产生 4 条
`7010: no files found` 警告，不影响 x86/x64 安装包。

---

## 7. 验证本次修复确实进入了二进制

LTCG（`/GL`）会把 `.obj` 变成 ANONYMOUS OBJECT，COFF 符号表为空，
`dumpbin /symbols` 查不到函数名。改用 A/B 哈希对比：

```powershell
git diff > $env:TEMP\fix.patch          # 先备份
git stash push -- WeaselTSF/            # 回到修复前
build.bat weasel
(Get-FileHash output\weaselx64.dll -Algorithm SHA256).Hash   # baseline
git stash pop
build.bat weasel
(Get-FileHash output\weaselx64.dll -Algorithm SHA256).Hash   # fixed
```

实测结果：

```
baseline  E4619C5B3745EA1BFDB4B96C4F35FDFCF7BC5E8C96B6B686E40C3A9DB60B9C8B
fixed     D30A929BF22DFD52B1869F75FCEF359582AE7619701620B8394B635FAA453AA4
```

哈希不同 → 源码改动确实进了产物。

> `git stash` 不会动未跟踪的 `include/afxres.h` 与 `docs/`，
> 所以构建过程中不会因为缺头文件而中断。

---

## 8. 注意事项

**`include/afxres.h` 是本机构建用的临时 shim，不是仓库的一部分。**
它没有被 `.gitignore` 覆盖，会以未跟踪文件出现。提交前请确认：

```powershell
git status --short
```

若要提交修复，**不要**把这个文件带进去（上游 CI 的 runner 镜像自带 MFC）。
装了 MFC 组件后删掉它即可。

其他本地状态（均不在版本控制内）：

- `deps\boost_1_84_0\`、 boost 编译出的 `deps\boost_1_84_0\stage\lib\*.lib`
- `deps\afxresshim\`（早期尝试用的目录，已废弃，可删）
- `deps\boost_1_84_0\user-config.jam`（b2 尝试残留，无效，可删）
- `D:\VS2022` → VS 安装目录的 junction（b2 尝试残留，可删）
- `env.bat`、`msbuild\`、`weasel.props`、`output\*`（均在 `.gitignore`）
- `output\data\` 下的 Rime 数据（`/output/data/*.yaml` 被忽略）

---

## 9. 手工脚本位置

以下脚本在仓库外的临时目录，如需长期使用请复制进仓库：

- `%TEMP%\opencode\build_boost_libs.ps1` —— 用 cl.exe 直接编 5 个 boost 库
- `%TEMP%\opencode\build_weasel.bat` —— vcvars + msbuild 单工程构建封装
- `%TEMP%\opencode\boostlib_{x64,x86}.bat` —— 上面脚本生成的 cl/lib 命令