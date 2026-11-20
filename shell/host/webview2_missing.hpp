#ifndef DEVAGENTS_WEBVIEW2_MISSING_HPP
#define DEVAGENTS_WEBVIEW2_MISSING_HPP
// P1-5 (R2 C3, 11-nov): sin el runtime de Microsoft WebView2 la cabina no
// puede mostrarse. Antes el host destruía la ventana y salía con código 1 sin
// decir nada. Ahora main.cpp comprueba el runtime antes de crear la ventana,
// enseña este mensaje en un diálogo nativo y sale con kExitCode.
//
// Lo que se decide aquí es puro (texto y código) para probarlo sin WebView2.
#include <string>

namespace beats {
namespace webview2_missing {

// Código de salida documentado del host cuando falta WebView2. Distinto de 1
// (fallo genérico de arranque) para que un instalador, un script o el soporte
// puedan distinguir este caso sin leer el registro.
constexpr int kExitCode = 3;

// Nombre del instalador Evergreen de Microsoft que puede viajar junto al
// ejecutable de DevAgents.
inline const wchar_t *SetupFileName() {
  return L"MicrosoftEdgeWebview2Setup.exe";
}

// `bundledSetup`: ruta completa del instalador si existe junto al ejecutable;
// vacía si no está.
inline std::wstring Message(const std::wstring &bundledSetup) {
  std::wstring text =
      L"DevAgents necesita Microsoft Edge WebView2 Runtime para mostrar su "
      L"ventana, y no está instalado en este equipo.\n\n"
      L"Se instala con el instalador de WebView2 Evergreen de Microsoft "
      L"(gratuito, requiere conexión a internet).\n\n";
  if (!bundledSetup.empty()) {
    text += L"DevAgents trae ese instalador. Ejecútalo y vuelve a abrir "
            L"DevAgents:\n";
    text += bundledSetup;
    text += L"\n\n";
  } else {
    text += L"Descárgalo desde la página oficial de Microsoft "
            L"(https://developer.microsoft.com/microsoft-edge/webview2/), "
            L"ejecútalo y vuelve a abrir DevAgents.\n\n";
  }
  text += L"DevAgents se cierra ahora (código de salida ";
  text += std::to_wstring(kExitCode);
  text += L").";
  return text;
}

inline const wchar_t *Title() { return L"DevAgents: falta Microsoft WebView2"; }

} // namespace webview2_missing
} // namespace beats
#endif
