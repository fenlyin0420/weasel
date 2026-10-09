# Ctrl+Space 双触发：排查记录

> **这是排查过程记录，包含若干已被证伪的假设，请勿照搬其中的结论。**
> 最终根因、修复方案与验证结果见 **[`ctrl-space-fix.md`](./ctrl-space-fix.md)**。
>
> 本文中「把翻转改成按 compartment 新值推导」与「在按键层拦截 Ctrl+Space」
> 两个方案均已被实测否决，理由见该文档第 4 节。本文档正文写作时修复尚未
> 落地，因此多处结论后来被推翻，特此标注。

调查日期：2026-10-09

---

## 1. 问题描述

在 Windows 资源管理器中重命名文件/文件夹时，按 `Ctrl+Space` 切换中英文，
一次按键被触发两次（"中 → 英 → 中"），净效果为零，看起来完全没反应。
其他应用（如记事本、浏览器）中同一快捷键工作正常。

相关上游 issue：[#1530 Win11下, 重命名文件时 Ctrl+Space 切换输入法有时灵有时不灵](https://github.com/rime/weasel/issues/1530)
（该 issue 被以"PowerToys 占用快捷键"关闭，未做代码层面定位；本仓库 HEAD 亦未包含该场景的修复）

---

## 2. 调用链

小狼毫的 `Ctrl+Space` 存在**两条互相独立、互不知情的处理路径**：

```
                       Ctrl+Space
                            │
        ┌───────────────────┴────────────────────┐
        │                                        │
  (A) 操作系统 / TSF 打开-关闭 compartment      (B) 按键事件 → librime
        │                                        │
  GUID_COMPARTMENT_KEYBOARD_OPENCLOSE           ConvertKeyEvent()
  OnChange → _HandleCompartment                 (KeyEvent.cpp:21-22, 111-112)
        │                                        │  keycode=ibus::space(0x020)
  Compartment.cpp:244-266                        │  mask=CONTROL_MASK
        │                                        │
  _status.ascii_mode = !_status.ascii_mode       _ProcessKeyEvent → IPC
        │  (Compartment.cpp:256)                 → RimeWithWeasel::ProcessKeyEvent
        │                                        → rime_api->process_key()
        └───────────────────┬────────────────────┘
                            │
              两条路径都可能各自翻转一次 ascii_mode
              → 两次翻转 = 净效果为零
```

### 路径选择由注册表决定

`WeaselTSF::OnSetThreadFocus`（`WeaselTSF.cpp:173-177`）读取
`HKCU\Software\Rime\weasel\ToggleImeOnOpenClose`：

| 取值 | `_isToOpenClose` | Ctrl+Space 语义 | 按键是否转发给 librime |
|---|---|---|---|
| `yes`（`/toggleime`） | `TRUE` | 开关输入法（IME on/off） | **否**，见下 |
| 其他（含缺省、`/toggleascii`） | `FALSE` | 切换 ascii_mode | **是** |

安装默认是 `/toggleascii`（CHANGELOG #1364），所以绝大多数用户处于
`_isToOpenClose == FALSE` 的分支 —— **路径 (B) 一直存在**。

`KeyEventSink.cpp:14` 是唯一的按键闸门：

```cpp
if ((_isToOpenClose && !_IsKeyboardOpen()) || _IsKeyboardDisabled()) {
    *pfEaten = FALSE;
    return;
}
```

`_isToOpenClose == FALSE` 时这个条件恒不成立，**Ctrl+Space 一定会被转发给
librime**，无论路径 (A) 是否同时发生。

---

## 3. 缺陷定位

### 缺陷 1：compartment 回调里无条件翻转缓存状态（主因）

`WeaselTSF/Compartment.cpp:255-266`：

```cpp
} else {
    _status.ascii_mode = !_status.ascii_mode;      // ← 缺陷：翻转本地缓存
    _SetKeyboardOpen(true);                        // ← 缺陷：在 OnChange 内写同一 compartment
    if (_pLangBarButton && _pLangBarButton->IsLangBarDisabled())
        _EnableLanguageBar(true);
    _HandleLangBarMenuSelect(_status.ascii_mode
                                 ? ID_WEASELTRAY_ENABLE_ASCII
                                 : ID_WEASELTRAY_DISABLE_ASCII);
    if (_pEditSessionContext)
        m_client.ClearComposition();
    _UpdateLanguageBar(_status);
}
```

两个问题：

1. **翻转而非推导**。`OnChange` 回调没有携带"新值是多少"这个信息，代码就靠
   `!` 翻一下。这使得**同一个 `OnChange` 事件被投递两次，结果与投递零次完全相同**。
   只要 `OnChange` 不是恰好投递一次，中英切换就必然失效。
   这是本 bug 的结构性根源：**事件处理不是幂等的**。

2. **重入**。`_SetKeyboardOpen(true)`（`Compartment.cpp:162-178`）对
   `GUID_COMPARTMENT_KEYBOARD_OPENCLOSE` 调用 `SetValue`。操作系统在
   Ctrl+Space 时把该值置为 `FALSE`，Weasel 又置回 `TRUE` —— 值发生了变化，
   `ITfCompartment::SetValue` 会再次触发 `OnChange`，重入 `_HandleCompartment`。
   第二次进入时 `_SetKeyboardOpen(true)` 因值已是 `TRUE` 不再通知，
   所以递归恰好两层后终止，但 **ascii_mode 已经被翻了两次**。

   旁证：同文件 `Compartment.cpp:267-276` 处理
   `GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION` 的分支里也调用
   `_SetCompartmentDWORD`，而线上没有出现无限递归 —— 说明 TSF 的
   `SetValue` 只在**值确实变化**时才通知。所以上面 FALSE→TRUE 这一跳是真实发生的。

3. **本地状态与服务端状态各说各话**。`_status.ascii_mode` 是 TSF 侧缓存，
   真正的 ascii_mode 在 librime 里。`_HandleLangBarMenuSelect` 只是通过 IPC
   让服务端 `SetOption`（`WeaselServerImpl.cpp:116-121`），服务端随后回吐状态。
   本地这个 `!` 翻转是在**猜测**服务端会变成什么，两者存在竞态。

### 缺陷 2：语言栏本地状态同样是无保护翻转

`WeaselTSF/LanguageBar.cpp:151-160`：

```cpp
if (click == TF_LBI_CLK_LEFT) {
    _pTextService->_HandleLangBarMenuSelect(
        ascii_mode ? ID_WEASELTRAY_DISABLE_ASCII : ID_WEASELTRAY_ENABLE_ASCII);
    ascii_mode = !ascii_mode;      // ← 同样的猜测式翻转
    ...
}
```

同一类问题。服务端状态稍后会通过 `UpdateWeaselStatus`
（`LanguageBar.cpp:252-265`）纠正，但在纠正之前图标显示的是猜测值。

### 缺陷 3：按键去重护栏对 Ctrl+Space 不生效

`WeaselTSF/KeyEventSink.cpp:76-147` 的 Test/Down 配对护栏：

```cpp
STDMETHODIMP WeaselTSF::OnTestKeyDown(..., BOOL* pfEaten) {
  if (_fTestKeyDownPending) { *pfEaten = TRUE; return S_OK; }
  _ProcessKeyEvent(wParam, lParam, pfEaten);
  ...
  if (*pfEaten)                  // ← 只在"吃掉"时才置位
    _fTestKeyDownPending = TRUE;
```

`_fTestKeyDownPending` 仅在按键被**吃掉**时置位。而 `_isToOpenClose == FALSE`
分支下 Ctrl+Space 通常不被吃掉（librime 未绑定 Control+space 时
`ProcessKeyEvent` 返回 FALSE），于是：

- 护栏不生效 → 应用若重复调用 `OnTestKeyDown`（DirectUI 类控件常见），
  每次都会真的走一遍 `_ProcessKeyEvent` 并发出 IPC；
- `_ProcessKeyEvent`（`KeyEventSink.cpp:11-63`）内没有任何重复抑制，
  也没有任何基于时间的 debounce（全仓库唯一的 `GetTickCount()` 在
  `WeaselTSF.cpp:13-20`，用于限流错误弹窗，与此无关）。

已有的 Caps_Lock 去重（`KeyEventSink.cpp:40-58`，`keycode == ibus::Caps_Lock`）
是按键码硬编码的专用逻辑，Ctrl+Space 没有对应实现。

---

## 4. 为什么偏偏是资源管理器重命名？

以下是需要运行时验证的假设，按可能性排序。当前证据只能确定
"**双重投递发生了，且翻转逻辑不幂等**"，还不能确定第二个投递来自哪里。

### 假设 1（最可能）：两条路径同时生效

路径 (A) 与 (B) 都执行了"切换 ascii_mode"，于是互相抵消。

- 路径 (A) 生效 → 操作系统的 `Ctrl+Space` 系统级处理被触发，
  `GUID_COMPARTMENT_KEYBOARD_OPENCLOSE` 变化 → `OnChange` → 翻转一次。
- 路径 (B) 生效 → `KeyEventSink.cpp:14` 未拦截，按键进入 librime
  → `rime_api->process_key(0x020, CONTROL_MASK)` → 若用户
  `default.custom.yaml` 里绑定了 `Control+space`，librime 再翻转一次。

为什么重命名场景下路径 (A) 没被抑制：资源管理器的重命名编辑框是
DirectUI 宿主控件，它自己处理 `WM_KEYDOWN` 并可能绕过
`ITfKeystrokeMgr` 的 eaten 标志去触发系统级 `Ctrl+Space` 处理，
使得即使 Weasel 吃了键，compartment 依然变化。

### 假设 2：重入

`Compartment.cpp:257` 的 `_SetKeyboardOpen(true)` 自身产生第二次 `OnChange`
（见缺陷 1 第 2 点）。这条路径**与是否资源管理器无关**，但只有在
"Ctrl+Space 真的导致 compartment 变成 `FALSE`"时才触发。
若资源管理器重命名时额外做了 `SetValue`（例如控件初始化/失焦），
就会稳定命中。

### 假设 3：控件重复投递按键事件

DirectUI 编辑控件在初始化或获得焦点时可能重复调用 `OnTestKeyDown`。
因为缺陷 3 使护栏失效，重复的 `OnTestKeyDown` 每次都会发出 IPC。
若此时 librime 侧存在 `Control+space` 绑定，即为多次翻转。

### 假设 4：外部程序抢键

[#1530](https://github.com/rime/weasel/issues/1530) 中报告者最终归因于 PowerToys。
这不能解释"只在重命名时出错"，但可能叠加在上面。

---

## 5. 已实施的修复

设计原则：**让重复事件无害（幂等），并把 `Ctrl+Space` 收敛到单一处理路径。**

改动共 5 个文件，44 行新增 / 15 行删除。

### 5.1 `WeaselTSF/Compartment.cpp` — 核心修复

`_HandleCompartment` 现在按 compartment 的**新值**推导目标状态，
而不是翻转缓存布尔值；并且只响应真正的状态跃迁。

```cpp
const BOOL isOpen = _IsKeyboardOpen();
if (isOpen == _lastOpenCloseValue)
  return S_OK;
_lastOpenCloseValue = isOpen;
...
} else {
  _status.ascii_mode = !isOpen;
  _SetKeyboardOpen(true);
  _lastOpenCloseValue = TRUE;
  ...
}
```

两处改动互相配合，缺一不可：

1. **推导而非翻转** —— `OnChange` 重复投递时，算出的目标值一致，
   不会像 `!` 翻转那样第二次把结果抵消掉。
2. **只处理跃迁 + 主动记录自身写入** —— `_SetKeyboardOpen(true)`
   会因 FALSE→TRUE 的变化再次触发 `OnChange`。由于我们主动把
   `_lastOpenCloseValue` 记为 `TRUE`，这次回声以及任何迟到的重复通知
   都会被开头的相等判断挡掉。

至此缺陷 1 的三个子问题（不幂等、重入、本地与服务端状态脱节）
一并解决：`_SetKeyboardOpen` 之前不再重复执行 `ClearComposition()`、
托盘刷新与状态提示闪烁；`_SyncStatusFromServer()` 让 `_status`
以服务端真实状态为准，本地推导仅用于决定该发哪条命令。

### 5.2 `WeaselTSF/KeyEventSink.cpp` — 收敛为单一路径

在 `_isToOpenClose == FALSE`（安装默认）时，Ctrl+Space 交给
compartment 路径处理，不再转发给 librime：

```cpp
static bool IsCtrlSpace(const weasel::KeyEvent& ke) {
  const UINT ctrl_space_mask =
      static_cast<UINT>(ibus::CONTROL_MASK) |
      static_cast<UINT>(ibus::SHIFT_MASK) |
      static_cast<UINT>(ibus::ALT_MASK) |
      static_cast<UINT>(ibus::LOCK_MASK);
  return ke.keycode == ibus::space &&
         (ke.mask & ctrl_space_mask) == static_cast<UINT>(ibus::CONTROL_MASK);
}
...
if (!_isToOpenClose && IsCtrlSpace(ke)) {
  *pfEaten = TRUE;
  return;
}
```

要点：

- 同时吃掉 **key-down 与 key-up**（判断不看 `RELEASE_MASK`），
  否则键会被吃一半，松开时状态错乱。
- 只拦纯 `Ctrl+Space`。`Ctrl+Shift+Space`、`Ctrl+Alt+Space`、
  CapsLock 开启时的 `Ctrl+Space` 一律放行，交给 librime 正常处理。
- 附带收益：这条路径返回 `*pfEaten = TRUE`，使得 `KeyEventSink.cpp`
  的 `_fTestKeyDownPending` 护栏（仅在按键被吃掉时置位）对 Ctrl+Space
  **首次生效**。此前护栏对该键完全不生效，控件重复投递的
  `OnTestKeyDown` 每次都会真的发出 IPC —— 缺陷 3 顺带被覆盖。

### 5.3 `WeaselTSF/LanguageBar.cpp` — 删除猜测式翻转

左键切换改由新的 `_ToggleAsciiModeFromLangBar()` 承担，
本地不再翻转 `ascii_mode`，而是拉取服务端确认后的状态：

```cpp
void WeaselTSF::_ToggleAsciiModeFromLangBar() {
  const bool wasAsciiMode = _status.ascii_mode;
  _HandleLangBarMenuSelect(wasAsciiMode ? ID_WEASELTRAY_DISABLE_ASCII
                                        : ID_WEASELTRAY_ENABLE_ASCII);
  if (!_SyncStatusFromServer())
    _status.ascii_mode = !wasAsciiMode;
  _UpdateLanguageBar(_status);
}
```

`_UpdateLanguageBar` 会调用 `UpdateWeaselStatus`
（`LanguageBar.cpp:252-265`）刷新图标。服务端不可达时才回退到翻转，
保证图标不会卡住不动。

### 5.4 `WeaselTSF/WeaselTSF.cpp` / `WeaselTSF.h`

- `ActivateEx` 在 `_InitCompartment()` **之前**记录初始 compartment 值。
  此时 sink 尚未 advise，若不预置，首次 `OnChange` 会把
  `_lastOpenCloseValue` 初始化成一个错误的值。
- 抽出 `_SyncStatusFromServer()`，替换 `Compartment.cpp` 与
  `WeaselTSF.cpp` 中三处重复的 `ResponseParser` + `GetResponseData`
  代码（原先 `Compartment.cpp` 里还有一个未使用的 `bool ok`）。

---

## 6. 未采纳的方案

### 6.1 基于时间的 debounce（改动 5，原方案）

原计划在 `_ProcessKeyEvent` 里对重复按键做 30ms 窗口抑制，
现**未采纳**。原因：

- 它只是兜底，而结构性修复（幂等化 + 单一路径）已经覆盖了三种假设；
- 时间窗口会误吞用户在 30ms 内连续按两次 Ctrl+Space 的合法操作，
  属于用新缺陷换旧缺陷；
- 单纯的按键去重解决不了「两条路径各翻转一次」互相抵消的问题。

### 6.2 `ctrl_space_handled_by_tsf` 配置开关

原计划用配置项降低 5.2 的破坏性风险，现**未采纳**。
`ToggleImeOnOpenClose != yes` 模式下 Ctrl+Space 的语义本就是
ascii_mode 切换，语义已经收敛到一处，开关只会让行为再次分叉。
若将来需要为「用户禁用系统快捷键 + librime 自行处理 Ctrl+Space」
的场景留后门，再加不迟。

---

## 7. 已知的行为变更与风险

| 场景 | 变化 |
|---|---|
| 用户在 `default.custom.yaml` 的 `key_binder` 绑定 `Control+space` | 该绑定在默认模式下不再生效（按键被 5.2 拦下）。实际上它此前也无法可靠生效 —— TSF compartment 路径在系统层面先于 librime 生效（见 issue #1409）。若用户**同时**用注册表禁用了系统 Ctrl+Space 快捷键（issue #717 的做法），compartment 不再变化，此时该绑定将完全失效。 |
| `Ctrl+Shift+Space` / `Ctrl+Alt+Space` | 不受影响，照常转发 librime。 |
| `/toggleime` 模式（`_isToOpenClose == TRUE`） | 5.1 的跃迁判断同样生效，行为不变：Ctrl+Space 仍开关输入法，不切换 ascii_mode。 |
| 语言栏左键点击 | 图标改为等服务端确认后刷新，不再立即翻转。正常情况下感知不到差异。 |
| 编码中切换中英文 | 预编辑串仍按原逻辑 `ClearComposition`（issue #1843 提到的行为），本次未改动。 |
| `global_ascii: true` 多会话同步 | 服务端逻辑（`RimeWithWeasel.cpp:778-785`）未改动。 |

---

## 8. 验证状态

### 8.1 编译验证（已完成）

**Release x64 + Win32 全量构建通过，0 error 0 warning。**
构建环境的坑与完整步骤见 [`build-on-windows.md`](./build-on-windows.md)。

产物：

| 文件 | 架构 |
|---|---|
| `output\weasel.dll` | x86 IME |
| `output\weaselx64.dll` | x64 IME |
| `output\WeaselServer.exe` / `output\Win32\WeaselServer.exe` | x64 / x86 |
| `output\WeaselDeployer.exe` / `output\Win32\WeaselDeployer.exe` | x64 / x86 |
| `output\WeaselSetup.exe` | x86 |
| `output\archives\weasel-0.17.4.50.d73f629-installer.exe` | NSIS 安装包 |

**修复确实进入二进制的证明**：LTCG 下 `.obj` 是 ANONYMOUS OBJECT，
`dumpbin /symbols` 查不到符号，故改用 A/B 哈希对比 ——
`git stash` 掉改动重建一次、恢复后重建一次：

```
baseline (未修复) E4619C5B3745EA1BFDB4B96C4F35FDFCF7BC5E8C96B6B686E40C3A9DB60B9C8B
fixed    (已修复) D30A929BF22DFD52B1869F75FCEF359582AE7619701620B8394B635FAA453AA4
```

两个哈希不同，说明改动确实编进了 `weaselx64.dll`。

行尾已统一为 CRLF，改动行均 ≤ 80 列。**CI 的 clang-format lint 未本地运行**
（本机无 clang-format），格式以 CI 为准。

> ⚠️ `include/afxres.h` 是本机构建用的 MFC 头文件 shim（VS Community 不提供
> MFC 组件），**不是仓库的一部分，提交前请勿带上**。详见
> [`build-on-windows.md`](./build-on-windows.md) 第 5、8 节。

### 8.2 功能验证（未完成，必须人工执行）

编译验证只能证明代码正确，**不能证明 bug 已修复** —— 因为第二次投递的
来源（假设 1/2/3 中的哪一个）仍未在运行时确认。修复按「无论哪个假设
成立都必须成立」的原则设计，但仍需实机确认。

步骤：

1. 编译安装。
2. 资源管理器 → 选中文件 → `F2` 进入重命名。
3. 按一次 `Ctrl+Space`，确认中/英切换生效；再按一次，确认能切回来。
4. 记事本中重复，作为对照组。
5. 确认 `Ctrl+Shift+Space`、`Ctrl+Alt+Space` 行为未变。
6. 若装有 `/toggleime`（`ToggleImeOnOpenClose = yes`），确认该模式下
   Ctrl+Space 仍是开关输入法。
7. 语言栏左键点击，确认图标正常刷新。
8. 编码过程中切换，确认无异常。

若仍复现，需要 6.1 的运行时日志定位第二次投递的真实来源。

### 8.3 若需加日志定位

在 `_HandleCompartment` 与 `_ProcessKeyEvent` 中记录：

- `OnChange` 被调用几次、每次 `_IsKeyboardOpen()` 的值；
- `ibus::space + CONTROL_MASK` 的 down/up 各被转发几次、
  `m_client.ProcessKeyEvent` 的返回值。

对照：

| OnChange 次数 | 按键转发次数 | 说明 | 对应假设 |
|---|---|---|---|
| 1 | 0 | 正常（修复后应为这一行） | — |
| 2 | 0 | 纯重入 | 假设 2 |
| 1 | 2 | 按键被重复投递 | 假设 3 |
| 1 | 1（且 librime 也翻转） | 两条路径都生效 | 假设 1 |

---

## 9. 改动文件清单

| 文件 | 改动 |
|---|---|
| `WeaselTSF/Compartment.cpp` | 幂等化 + 主动记录自身写入；抽出并调用 `_SyncStatusFromServer()` |
| `WeaselTSF/KeyEventSink.cpp` | 新增 `IsCtrlSpace()`，拦截纯 Ctrl+Space 不转发 librime |
| `WeaselTSF/LanguageBar.cpp` | 新增 `_ToggleAsciiModeFromLangBar()`，`OnClick` 改为调用它 |
| `WeaselTSF/WeaselTSF.cpp` | `ActivateEx` 预置 `_lastOpenCloseValue`；`OnSetThreadFocus` 改用新助手 |
| `WeaselTSF/WeaselTSF.h` | 新增 `_lastOpenCloseValue` 成员、`_SyncStatusFromServer()`、`_ToggleAsciiModeFromLangBar()` 声明 |

`CHANGELOG.md` 无需手改 —— 它由 commit message 经 conventional-changelog
生成（条目自带 commit 链接），手写会与生成结果冲突。变更说明写进
commit message 即可。

---

## 10. 仍待确认

1. **第二次投递的真实来源**（假设 1/2/3）—— 需要 8.3 的运行时日志。
   修复对三者都成立，但只有实机能确认命中的到底是哪个。
2. **用户在 `default.custom.yaml` 绑定 `Control+space` 的用法**
   （issue #424、#1409）—— 5.2 会使其在默认模式下失效。
   是否需要为此加配置开关，取决于是否要照顾这类用户。
3. **CHANGELOG 条目** —— 无需手改，由 commit message 生成；
   提交时在 message 里写明「fix(WeaselTSF): ...」即可。