# Ctrl+Space 双触发修复

版本：`0.17.5`（本地修复版，基于上游 `0.17.4`）
分支：`dev`
相关上游 issue：[#1530](https://github.com/rime/weasel/issues/1530)（同类症状，未做代码定位）

---

## 1. 现象

在资源管理器中按 `Ctrl+Space` 切换中英文，一次按键被触发两次
（`中 → 英 → 中`），净效果为零。其他程序（记事本、Typora、chrome、
终端）均正常。

---

## 2. 根因

`Ctrl+Space` 在 GUI 程序中会同时走**两条互相独立的 ascii_mode 切换路径**，
在同一毫秒内各翻转一次，互相抵消。

日志证据（Explorer，一次按键，tick=42734）：

```
[42734] key vk=32 lParam=0x390001                          ← 按下
[42750]   -> forwarded to librime, eaten=1                  ← 路径 A
[42750] OnChange OPENCLOSE enter: isOpen=0 ... ascii=0
[42750]   -> flipped ascii_mode=1                          ← 路径 B
[42796]     _SetKeyboardOpen(1) -> hr=0x8000ffff now=0
[42796]   -> after sync ascii_mode=1
[42906] key vk=32 lParam=0xc0390001                        ← 松开
```

| | 路径 | 实现位置 |
|---|---|---|
| A | librime 自己的 `key_binder` 绑定 `Control+space → toggle: ascii_mode` | 用户配置 `default.custom.yaml` / `luna_pinyin_simp.custom.yaml` |
| B | `GUID_COMPARTMENT_KEYBOARD_OPENCLOSE` 变化 → `_isToOpenClose == false` 分支翻转 | `WeaselTSF/Compartment.cpp` `_HandleCompartment` |

### 为什么只有资源管理器触发路径 B

路径 B 只在 **Windows 自己又处理了一次 Ctrl+Space**（即系统级IME 开关）时
才会发生。正常情况下路径 A 吃掉按键后，系统不应再处理。

对比其他程序的日志，同样一次按键只有：

```
[41203] key vk=32 lParam=0x390001
[41203]   -> forwarded to librime, eaten=1
[41359] key vk=32 lParam=0xc0390001
```

**完全没有 `OnChange`。**

资源管理器的重命名编辑框是 DirectUI 宿主控件，自己处理 `WM_KEYDOWN`。
即使文本服务已经吃掉按键（`eaten=1`），它仍把这次按键交给系统层，
于是 Windows 又执行了一次 IME 开关，触发路径 B。

终端正常是因为 conhost 走 IMM32，完全绕开 TSF。

---

## 3. 修复

核心原则：**这次切换如果已经发生过，compartment 通知就不再翻转。**

### 3.1 消除重复翻转

`WeaselTSF/WeaselTSF.h` 新增：

```cpp
DWORD _dwSkipAsciiToggleTick = 0;
```

`WeaselTSF/KeyEventSink.cpp` —— Ctrl+Space 被 librime 接受时打标记：

```cpp
if (*pfEaten && !_isToOpenClose && IsCtrlSpacePress(ke))
  _dwSkipAsciiToggleTick = GetTickCount();
```

`WeaselTSF/Compartment.cpp` —— 200ms 内的通知视为同一次按键，改为采纳服务端现状：

```cpp
const bool toggleAlreadyDone =
    _dwSkipAsciiToggleTick != 0 && (GetTickCount() - _dwSkipAsciiToggleTick) < 200;
if (toggleAlreadyDone) {
  _RequestKeyboardOpen();
  _SyncStatusFromServer();
  _UpdateLanguageBar(_status);
} else {
  _status.ascii_mode = !_status.ascii_mode;
  ...
}
```

标记只在 librime **确实接管了这次按键**时才打，因此不影响没有绑定
`Control+space` 的用户 —— 他们仍然走原来的翻转逻辑。

### 3.2 修复 `_SetKeyboardOpen` 返回 E_FAIL

日志显示按键路径中的写入全部失败：

```
[42796] _SetKeyboardOpen(1) -> hr=0x8000ffff now=0
```

而在 `ActivateEx` 中同样的调用成功（`hr=0x00000000`）。原因是
`ITfCompartment::SetValue` 在**该 compartment 自己的变更通知内部**会被拒绝
（重入写入）。

改为延迟到按键路径执行：

```cpp
void WeaselTSF::_RequestKeyboardOpen() {
  _fOpenKeyboardPending = TRUE;
}
```

```cpp
// KeyEventSink.cpp
if (_fOpenKeyboardPending && !IsCtrlSpacePress(ke)) {
  _fOpenKeyboardPending = FALSE;
  _dwSkipAsciiToggleTick = GetTickCount();   // 必须在写入之前标记
  _SetKeyboardOpen(TRUE);
}
```

两个防护细节：

- 延迟写入**跳过 Ctrl+Space 本身**，避免与正在进行的切换交错
- 标记在 `SetValue` **之前**设置，同步回调与异步通知都能拦下

`ActivateEx` 早就在做同样的恢复（线程获得焦点时重开键盘），
所以延迟到下一次按键是安全的。

### 3.3 附带改进：状态以服务端为准

- 新增 `_SyncStatusFromServer()`，替换三处重复的
  `ResponseParser` + `GetResponseData` 代码（原先 `Compartment.cpp`
  里还有一个未使用的 `bool ok`）。
- 语言栏左键切换改为 `_ToggleAsciiModeFromLangBar()`，不再本地猜测翻转，
  改为拉取服务端确认后的状态。

---

## 4. 被否决的两个方案

记录在此以免重蹈。

### 4.1 在 `KeyEventSink` 拦截纯 Ctrl+Space 不转发 librime

**想法**：Ctrl+Space 由 compartment 独占处理，转发给 librime 会造成双路翻转。

**结果**：致命回归。日志显示按键全被吞、`OnChange` 归零，GUI 程序里中英
彻底切不了；终端因走 IMM32 不受影响。**「终端正常、其他程序坏」正是这个
回归的指纹。**

**否决理由**：在没搞清按键实际走哪条路之前不能拦截按键。

### 4.2 把翻转改成按 compartment 新值推导

**想法**：翻转不幂等，重复投递会抵消，所以按值推导。

**结果**：逻辑上就错。代码会把键盘强制置回 open，下一次 Ctrl+Space 又变
FALSE，推导目标恒为「英文」，**第二次之后就卡在英文回不去**。

**否决理由**：这里的「翻转」是**正确**的，因为存在强制回写动作。
幂等性不能靠改写状态语义获得，只能靠抑制重复事件。

---

## 5. 一个重要的排查陷阱

排查期间，资源管理器**一直运行着旧版本的 `weasel.dll`**：

- TSF 注册的 `InprocServer32` 是 `C:\WINDOWS\system32\weasel.dll`
- explorer.exe 是长驻进程，在安装之前就把该 DLL 映射进了内存
- Windows 不会热重载已加载的 DLL

结果是我做的每一个版本，**资源管理器都没跑到过**，导致连续两轮
「修复无效」的误判。安装后必须重启 Explorer：

```powershell
taskkill /IM explorer.exe /F; Start-Process explorer.exe
```

> 这个效应**不限于资源管理器** —— 任何跨版本更新前就在运行的程序都会继续
> 用旧代码。「只在某个程序里出现」很大程度上是这个效应造成的假象。

---

## 6. 验证结果

用户实测通过。

| 场景 | 结果 |
|---|---|
| 资源管理器重命名框 `Ctrl+Space` | 一次切换 ✅ |
| 连按两次 | 两次切换 ✅ |
| Typora / chrome / 记事本 | 不受影响 ✅ |
| 终端 | 不受影响（走 IMM32）✅ |

编译：Release x64 + Win32 全量，**0 error 0 warning**。

安装包：`output\archives\weasel-0.17.5.0.d73f629-installer.exe`

---

## 7. 已知遗留问题

1. **`Ctrl+Shift+2` 之类的绑定需自行核对。** 修复只拦截纯 `Ctrl+Space`
   （`IsCtrlSpacePress` 排除了 Shift / Alt / CapsLock），其它组合不受影响。

2. **抑制窗口是 200ms。** 极端情况下（两��独立请求落在同一窗口内）
   后者可能被吞掉。实测未观察到。

3. **本仓库未跑 `clang-format` lint。** 构建环境无该工具，格式以
   Chromium 风格手工对齐（80 列、2 空格缩进）。

4. **未处理 `_SyncStatusFromServer()` 在语言栏点击路径上的额外往返开销。**
   当前可接受，未做优化。

---

## 8. 改动文件

| 文件 | 改动 |
|---|---|
| `WeaselTSF/WeaselTSF.h` | 新增 `_dwSkipAsciiToggleTick`、`_fOpenKeyboardPending`，声明 `_SyncStatusFromServer()`、`_RequestKeyboardOpen()`、`_ToggleAsciiModeFromLangBar()` |
| `WeaselTSF/Compartment.cpp` | 重复切换时不再翻转；键盘重开改为延迟请求；抽出 `_SyncStatusFromServer()` |
| `WeaselTSF/KeyEventSink.cpp` | 新增 `IsCtrlSpacePress()`；标记被 librime 接受的 Ctrl+Space；应用延迟的键盘重开 |
| `WeaselTSF/LanguageBar.cpp` | 左键切换改用 `_ToggleAsciiModeFromLangBar()`，不再本地翻转 |
| `WeaselTSF/WeaselTSF.cpp` | `OnSetThreadFocus` 改用 `_SyncStatusFromServer()` |

### 用户配置侧（不属于本仓库）

原问题配置里，`luna_pinyin_simp.custom.yaml` 用整体替换的方式重写了
`switches` 列表，删掉了基础 schema 中控制简繁的选项组
（`options: [zh_hant, zh_hans, zh_hant_hk, zh_hant_tw]`），
导致 `simplifier@zh_hans` 永不生效、输出变繁体；自造的 `zh_simp` 开关
没有绑定任何转换器，所以按 F4 无效。

修法是改用 `switches/@0`、`switches/@2` 按索引打补丁，并把
`Control+Shift+2` 绑到真实选项 `zh_hans`。详见
[`ctrl-space-double-toggle.md`](./ctrl-space-double-toggle.md)。

---

## 9. 排查工具

`docs/ctrl-space-double-toggle.md` 记录了完整排查过程，包括：

- 用文件日志（而非 journal）埋点的方法
- 「一次按键触发几次」的四种组合对照表
- 两个错误方案的推演与否决理由
- 资源管理器多实例 / 陈旧 DLL 的假设与验证

---

## 10. 给其他平台（ibus-rime / fcitx5-rime）的移植提示

Windows 侧的机制**不可直接移植**：

- 没有 TSF 的 `GUID_COMPARTMENT_KEYBOARD_OPENCLOSE`，路径 B 不存在
- 前端快捷键机制不同，需单独确认**框架层快捷键与 rime `key_binder`
  是否会同时响应同一次按键** —— 这是最可能的双翻转来源
- **先查守护进程/前端是否持有旧状态**（对应本文第 5 节的陷阱）