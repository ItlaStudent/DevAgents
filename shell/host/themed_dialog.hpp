#ifndef BEATS_THEMED_DIALOG_HPP
#define BEATS_THEMED_DIALOG_HPP
// Diálogo nativo con el tema de DevAgents (10-nov, petición del propietario:
// los MessageBox de Windows «no van con DevAgents»).
//
// Sigue siendo una ventana NATIVA del host, a propósito: las autorizaciones
// privilegiadas no se pueden pintar en la WebView, porque una página
// comprometida podría imitarlas o pulsarlas. Aquí solo cambia el aspecto:
// fondo oscuro, texto claro, acento ámbar y botones redondeados; el
// comportamiento es el de MessageBox (modal sobre el propietario, «No» por
// defecto cuando se pide, Esc = No/Cancelar, Enter = botón con foco).
// Solo cabecera y sin dependencias nuevas: DwmSetWindowAttribute se resuelve
// en tiempo de ejecución porque algunos binarios de prueba no enlazan dwmapi.
#include <algorithm>
#include <functional>
#include <string>
#include <windows.h>

namespace beats {
namespace themed {

// Remate D7 (10-nov): mensajes de HILO (hwnd nulo) que llegan mientras este
// dialogo modal tiene su propio bucle. Las respuestas de los workers del
// motor viajan asi (PostThreadMessageW); DispatchMessageW las descartaba y la
// peticion de la cabina se quedaba sin respuesta para siempre. main.cpp
// instala aqui su entrega; devuelve true si atendio el mensaje.
inline std::function<bool(const MSG &)> &ThreadMessages() {
  static std::function<bool(const MSG &)> handler;
  return handler;
}

enum class Kind { info, question, warning, error };
enum class Buttons { ok, yes_no };

struct Palette {
  COLORREF bg = RGB(0x12, 0x12, 0x11);
  COLORREF surface = RGB(0x1a, 0x19, 0x18);
  COLORREF border = RGB(0x2e, 0x2c, 0x2a);
  COLORREF fg = RGB(0xe4, 0xe0, 0xda);
  COLORREF muted = RGB(0x9a, 0x95, 0x8e);
  COLORREF highlight = RGB(0xe8, 0xa8, 0x68);
  COLORREF warning = RGB(0xc8, 0x92, 0x46);
  COLORREF danger = RGB(0xc4, 0x55, 0x3d);
  COLORREF info = RGB(0x63, 0x89, 0xa6);
};

namespace detail {

constexpr wchar_t kClass[] = L"DevAgentsThemedDialog";
constexpr int kFirstButton = 100;

struct State {
  Palette pal;
  std::wstring title, body;
  Kind kind = Kind::info;
  Buttons buttons = Buttons::ok;
  bool defaultNo = false;
  int result = IDCANCEL;
  bool done = false;
  HFONT titleFont = nullptr, bodyFont = nullptr, buttonFont = nullptr;
  HWND yes = nullptr, no = nullptr, ok = nullptr;
  int dpi = 96;
  RECT textRect{};
};

inline int Scale(int v, int dpi) { return MulDiv(v, dpi, 96); }

inline void SetDark(HWND hwnd, const Palette &pal) {
  using Fn = HRESULT(WINAPI *)(HWND, DWORD, LPCVOID, DWORD);
  static Fn fn = [] {
    HMODULE m = LoadLibraryW(L"dwmapi.dll");
    return m ? reinterpret_cast<Fn>(GetProcAddress(m, "DwmSetWindowAttribute"))
             : nullptr;
  }();
  if (!fn)
    return;
  BOOL dark = TRUE;
  fn(hwnd, 20 /*DWMWA_USE_IMMERSIVE_DARK_MODE*/, &dark, sizeof(dark));
  COLORREF caption = pal.bg, text = pal.fg, border = pal.border;
  fn(hwnd, 35 /*DWMWA_CAPTION_COLOR*/, &caption, sizeof(caption));
  fn(hwnd, 36 /*DWMWA_TEXT_COLOR*/, &text, sizeof(text));
  fn(hwnd, 34 /*DWMWA_BORDER_COLOR*/, &border, sizeof(border));
  DWORD round = 2 /*DWMWCP_ROUND*/;
  fn(hwnd, 33 /*DWMWA_WINDOW_CORNER_PREFERENCE*/, &round, sizeof(round));
}

inline COLORREF KindColor(const State &s) {
  switch (s.kind) {
  case Kind::warning:
    return s.pal.highlight;
  case Kind::error:
    return s.pal.danger;
  case Kind::question:
    return s.pal.info;
  default:
    return s.pal.muted;
  }
}

inline const wchar_t *KindGlyph(Kind k) {
  switch (k) {
  case Kind::warning:
    return L"!";
  case Kind::error:
    return L"×";
  case Kind::question:
    return L"?";
  default:
    return L"i";
  }
}

inline void PaintButton(const DRAWITEMSTRUCT *di, const State &s) {
  const bool primary = GetFocus() == di->hwndItem;
  const bool pressed = (di->itemState & ODS_SELECTED) != 0;
  HDC dc = di->hDC;
  RECT r = di->rcItem;
  HBRUSH back = CreateSolidBrush(s.pal.bg);
  FillRect(dc, &r, back);
  DeleteObject(back);
  const int radius = Scale(8, s.dpi);
  HBRUSH fill = CreateSolidBrush(pressed ? s.pal.border : s.pal.surface);
  HPEN pen = CreatePen(PS_SOLID, Scale(1, s.dpi),
                       primary ? s.pal.highlight : s.pal.border);
  HGDIOBJ oldBrush = SelectObject(dc, fill);
  HGDIOBJ oldPen = SelectObject(dc, pen);
  RoundRect(dc, r.left, r.top, r.right, r.bottom, radius, radius);
  SelectObject(dc, oldBrush);
  SelectObject(dc, oldPen);
  DeleteObject(fill);
  DeleteObject(pen);
  wchar_t label[64] = {};
  GetWindowTextW(di->hwndItem, label, 63);
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, primary ? s.pal.highlight : s.pal.fg);
  HGDIOBJ oldFont = SelectObject(dc, s.buttonFont);
  DrawTextW(dc, label, -1, &r, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  SelectObject(dc, oldFont);
}

inline void Paint(HWND hwnd, State &s) {
  PAINTSTRUCT ps;
  HDC dc = BeginPaint(hwnd, &ps);
  RECT client;
  GetClientRect(hwnd, &client);
  HBRUSH bg = CreateSolidBrush(s.pal.bg);
  FillRect(dc, &client, bg);
  DeleteObject(bg);
  SetBkMode(dc, TRANSPARENT);
  // Insignia del tipo: círculo de contorno con su glifo.
  const int pad = Scale(22, s.dpi), badge = Scale(30, s.dpi);
  HPEN pen = CreatePen(PS_SOLID, Scale(2, s.dpi), KindColor(s));
  HGDIOBJ oldPen = SelectObject(dc, pen);
  HGDIOBJ oldBrush = SelectObject(dc, GetStockObject(NULL_BRUSH));
  Ellipse(dc, pad, pad, pad + badge, pad + badge);
  SelectObject(dc, oldPen);
  SelectObject(dc, oldBrush);
  DeleteObject(pen);
  RECT g{pad, pad, pad + badge, pad + badge};
  SetTextColor(dc, KindColor(s));
  HGDIOBJ oldFont = SelectObject(dc, s.titleFont);
  DrawTextW(dc, KindGlyph(s.kind), -1, &g,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  // Título y cuerpo.
  RECT t = s.textRect;
  SetTextColor(dc, s.pal.fg);
  RECT titleRect = t;
  DrawTextW(dc, s.title.c_str(), -1, &titleRect, DT_WORDBREAK | DT_CALCRECT);
  titleRect.right = t.right;
  DrawTextW(dc, s.title.c_str(), -1, &titleRect, DT_WORDBREAK);
  SelectObject(dc, s.bodyFont);
  SetTextColor(dc, s.pal.muted);
  RECT bodyRect{t.left, titleRect.bottom + Scale(8, s.dpi), t.right, t.bottom};
  DrawTextW(dc, s.body.c_str(), -1, &bodyRect, DT_WORDBREAK | DT_NOPREFIX);
  SelectObject(dc, oldFont);
  // Línea sobre la fila de botones.
  RECT line{0, client.bottom - Scale(60, s.dpi), client.right,
            client.bottom - Scale(60, s.dpi) + 1};
  HBRUSH lb = CreateSolidBrush(s.pal.border);
  FillRect(dc, &line, lb);
  DeleteObject(lb);
  EndPaint(hwnd, &ps);
}

inline LRESULT CALLBACK Proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  auto *s = reinterpret_cast<State *>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  switch (msg) {
  case WM_NCCREATE: {
    auto *cs = reinterpret_cast<CREATESTRUCTW *>(lp);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    break;
  }
  case WM_ERASEBKGND:
    return 1;
  case WM_PAINT:
    if (s) {
      Paint(hwnd, *s);
      return 0;
    }
    break;
  case WM_DRAWITEM:
    if (s) {
      PaintButton(reinterpret_cast<const DRAWITEMSTRUCT *>(lp), *s);
      return TRUE;
    }
    break;
  case WM_COMMAND:
    if (s) {
      int id = LOWORD(wp);
      if (id == IDCANCEL)
        id = s->buttons == Buttons::yes_no ? IDNO : IDOK;
      if (id == IDOK && s->buttons == Buttons::yes_no) {
        // Enter: el botón que tiene el foco.
        HWND f = GetFocus();
        id = f == s->yes ? IDYES : IDNO;
      }
      if (id == IDYES || id == IDNO || id == IDOK) {
        s->result = id;
        s->done = true;
        return 0;
      }
    }
    break;
  case WM_CLOSE:
    if (s) {
      s->result = s->buttons == Buttons::yes_no ? IDNO : IDOK;
      s->done = true;
      return 0;
    }
    break;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

inline HFONT MakeFont(int dpi, int pt, int weight) {
  return CreateFontW(-MulDiv(pt, dpi, 72), 0, 0, 0, weight, FALSE, FALSE, FALSE,
                     DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                     CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
                     L"Segoe UI");
}

} // namespace detail

// Muestra el diálogo y devuelve IDYES/IDNO (yes_no) o IDOK (ok).
inline int Show(HWND owner, const std::wstring &title, const std::wstring &body,
                Kind kind, Buttons buttons, bool defaultNo = true,
                const std::wstring &yesLabel = L"Sí",
                const std::wstring &noLabel = L"No") {
  using namespace detail;
  HINSTANCE inst = GetModuleHandleW(nullptr);
  static bool registered = false;
  if (!registered) {
    WNDCLASSEXW wc{sizeof(wc)};
    wc.lpfnWndProc = Proc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = kClass;
    wc.hIcon = LoadIconW(inst, MAKEINTRESOURCEW(1));
    registered = RegisterClassExW(&wc) != 0 ||
                 GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
  }
  State s;
  s.title = title;
  s.body = body;
  s.kind = kind;
  s.buttons = buttons;
  s.defaultNo = defaultNo;
  s.dpi = owner && IsWindow(owner) ? static_cast<int>(GetDpiForWindow(owner))
                                   : static_cast<int>(GetDpiForSystem());
  if (s.dpi <= 0)
    s.dpi = 96;
  s.titleFont = MakeFont(s.dpi, 11, FW_SEMIBOLD);
  s.bodyFont = MakeFont(s.dpi, 10, FW_NORMAL);
  s.buttonFont = MakeFont(s.dpi, 10, FW_SEMIBOLD);

  // Medidas: ancho fijo, alto según el texto.
  const int width = Scale(480, s.dpi);
  const int pad = Scale(22, s.dpi), badge = Scale(30, s.dpi);
  const int textLeft = pad + badge + Scale(14, s.dpi);
  const int textRight = width - pad;
  HDC mdc = GetDC(nullptr);
  RECT tr{0, 0, textRight - textLeft, 0}, br{0, 0, textRight - textLeft, 0};
  HGDIOBJ of = SelectObject(mdc, s.titleFont);
  DrawTextW(mdc, title.c_str(), -1, &tr, DT_WORDBREAK | DT_CALCRECT);
  SelectObject(mdc, s.bodyFont);
  DrawTextW(mdc, body.c_str(), -1, &br,
            DT_WORDBREAK | DT_CALCRECT | DT_NOPREFIX);
  SelectObject(mdc, of);
  ReleaseDC(nullptr, mdc);
  const int textH =
      (tr.bottom - tr.top) + Scale(8, s.dpi) + (br.bottom - br.top);
  const int clientH =
      std::max(pad + badge, pad + textH) + Scale(22, s.dpi) + Scale(60, s.dpi);
  s.textRect = RECT{textLeft, pad + Scale(4, s.dpi), textRight,
                    pad + Scale(4, s.dpi) + textH + Scale(4, s.dpi)};

  const DWORD style = WS_POPUP | WS_CAPTION | WS_SYSMENU;
  const DWORD exStyle = WS_EX_DLGMODALFRAME;
  RECT wr{0, 0, width, clientH};
  AdjustWindowRectExForDpi(&wr, style, FALSE, exStyle, s.dpi);
  const int ww = wr.right - wr.left, wh = wr.bottom - wr.top;
  RECT anchor{};
  if (owner && IsWindow(owner))
    GetWindowRect(owner, &anchor);
  else
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &anchor, 0);
  const int x = anchor.left + ((anchor.right - anchor.left) - ww) / 2;
  const int y = anchor.top + ((anchor.bottom - anchor.top) - wh) / 3;

  HWND hwnd = CreateWindowExW(exStyle, kClass, L"DevAgents", style, x, y, ww,
                              wh, owner, nullptr, inst, &s);
  if (!hwnd) {
    DeleteObject(s.titleFont);
    DeleteObject(s.bodyFont);
    DeleteObject(s.buttonFont);
    const UINT flags = (buttons == Buttons::yes_no ? MB_YESNO : MB_OK) |
                       (defaultNo ? MB_DEFBUTTON2 : 0) |
                       (kind == Kind::error      ? MB_ICONERROR
                        : kind == Kind::warning  ? MB_ICONWARNING
                        : kind == Kind::question ? MB_ICONQUESTION
                                                 : MB_ICONINFORMATION);
    return MessageBoxW(owner, body.c_str(), title.c_str(), flags);
  }
  SetDark(hwnd, s.pal);
  const int bw = Scale(96, s.dpi), bh = Scale(32, s.dpi),
            gap = Scale(10, s.dpi);
  const int by = clientH - Scale(46, s.dpi);
  auto makeButton = [&](const std::wstring &label, int id, int bx) {
    HWND b = CreateWindowExW(
        0, L"BUTTON", label.c_str(),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW, bx, by, bw, bh, hwnd,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), inst, nullptr);
    SendMessageW(b, WM_SETFONT, reinterpret_cast<WPARAM>(s.buttonFont), TRUE);
    return b;
  };
  if (buttons == Buttons::yes_no) {
    s.no = makeButton(noLabel, IDNO, width - pad - bw);
    s.yes = makeButton(yesLabel, IDYES, width - pad - bw - gap - bw);
  } else {
    s.ok = makeButton(L"Aceptar", IDOK, width - pad - bw);
  }

  const bool ownerEnabled = owner && IsWindow(owner) && IsWindowEnabled(owner);
  if (ownerEnabled)
    EnableWindow(owner, FALSE);
  ShowWindow(hwnd, SW_SHOW);
  SetForegroundWindow(hwnd);
  SetFocus(buttons == Buttons::yes_no ? (defaultNo ? s.no : s.yes) : s.ok);

  MSG m{};
  BOOL got = 1;
  while (!s.done && (got = GetMessageW(&m, nullptr, 0, 0)) > 0) {
    if (m.hwnd == nullptr && ThreadMessages() && ThreadMessages()(m))
      continue;
    // Tab, flechas, Enter y Esc como en un diálogo; el foco repinta el borde.
    if (m.message == WM_KEYDOWN &&
        (m.wParam == VK_LEFT || m.wParam == VK_RIGHT) &&
        buttons == Buttons::yes_no) {
      SetFocus(GetFocus() == s.yes ? s.no : s.yes);
      InvalidateRect(s.yes, nullptr, TRUE);
      InvalidateRect(s.no, nullptr, TRUE);
      continue;
    }
    if (m.message == WM_KEYDOWN && m.wParam == VK_TAB) {
      HWND next =
          GetNextDlgTabItem(hwnd, GetFocus(), GetKeyState(VK_SHIFT) < 0);
      if (next)
        SetFocus(next);
      if (s.yes)
        InvalidateRect(s.yes, nullptr, TRUE);
      if (s.no)
        InvalidateRect(s.no, nullptr, TRUE);
      continue;
    }
    if (m.message == WM_KEYDOWN && m.wParam == VK_ESCAPE) {
      SendMessageW(hwnd, WM_COMMAND, IDCANCEL, 0);
      continue;
    }
    if (m.message == WM_KEYDOWN && m.wParam == VK_RETURN) {
      SendMessageW(hwnd, WM_COMMAND, IDOK, 0);
      continue;
    }
    TranslateMessage(&m);
    DispatchMessageW(&m);
  }
  // Un WM_QUIT recibido dentro de este bucle es del bucle principal: se repone.
  if (got == 0)
    PostQuitMessage(static_cast<int>(m.wParam));
  if (ownerEnabled)
    EnableWindow(owner, TRUE);
  DestroyWindow(hwnd);
  if (owner && IsWindow(owner))
    SetForegroundWindow(owner);
  DeleteObject(s.titleFont);
  DeleteObject(s.bodyFont);
  DeleteObject(s.buttonFont);
  return s.result;
}

} // namespace themed
} // namespace beats
#endif
