#pragma once
#include <WeaselIPCData.h>
#include <functional>
#include <memory>
#include <string>
#include <windows.h>
#include <wrl.h>

namespace weasel {
using namespace Microsoft::WRL;

template <typename T>
using an = std::shared_ptr<T>;
template <typename T>
using the = std::unique_ptr<T>;
typedef std::function<
    void(size_t* const, size_t* const, bool* const, bool* const)>
    UICallbackFunc;

enum ClientCapabilities {
  INLINE_PREEDIT_CAPABLE = 1,
};

class UIImpl;
class UI {
 public:
  UI();
  virtual ~UI();
  // 创建输入法界面
  bool Create(HWND parent);
  // 销毁界面
  void Destroy(bool full = false);
  // 界面显隐
  void Show();
  void Hide();
  void ShowWithTimeout(size_t millisec);
  BOOL IsCountingDown() const;
  BOOL IsShown() const;
  // 重绘界面
  void Refresh();
  // 置输入焦点位置（光标跟随时移动候选窗）但不重绘
  void UpdateInputPosition(RECT const& rc);
  // 更新界面显示内容
  void Update(Context const& ctx, Status const& status);
  Context& ctx() { return ctx_; }
  Context& octx() { return octx_; }
  Status& status() { return status_; }
  UIStyle& style() { return style_; }
  UIStyle& ostyle() { return ostyle_; }
  bool GetIsReposition();
  UICallbackFunc& uiCallback() { return _uiCallback; }
  // compatibility shim for existing call sites
  void SetUICallBack(const UICallbackFunc& func) { _uiCallback = func; }
  void SetCallback(const UICallbackFunc& func) { _uiCallback = func; }
  bool& InServer() { return in_server_; }
  HWND hwnd();
  /*
   * Set while the host reports no caret of its own through TSF. The panel then
   * asks the host's IMM32 composition window for the caret instead - the only
   * place a host that keeps its text out of the TSF document publishes it, and
   * where an IMM32 input method reads it from. Hosts that do report a caret
   * never set this, so their windows never see an input context created.
   */
  bool& ImmCaretProbe() { return imm_caret_probe_; }

 private:
  the<UIImpl> pimpl_;
  Context ctx_;
  Context octx_;
  Status status_;
  UIStyle style_;
  UIStyle ostyle_;
  bool in_server_;
  bool imm_caret_probe_ = false;
  UICallbackFunc _uiCallback;
};
}  // namespace weasel
