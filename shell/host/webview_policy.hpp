#ifndef BEATS_WEBVIEW_POLICY_HPP
#define BEATS_WEBVIEW_POLICY_HPP
// Ajustes y manejadores de seguridad de la WebView PRINCIPAL (y de los
// popouts, que comparten WebViewHost). La vista previa tiene los suyos en
// preview_policy.hpp. Las plantillas dejan inyectables las llamadas COM para
// probarlas sin crear una WebView ni tocar un perfil de navegador.
#include "WebView2.h"
#include <windows.h>

namespace beats {
namespace webview_policy {

// Cada ajuste se comprueba: un put_* que falla deja el valor por defecto de
// WebView2 (diálogos de script, menús, objetos del host), así que el arranque
// de la vista debe abortar en vez de ignorar el HRESULT.
template <class Settings>
inline HRESULT ApplyMainViewSettings(Settings *settings, bool devTools) {
  if (!settings)
    return E_POINTER;
  HRESULT result = settings->put_AreDevToolsEnabled(devTools ? TRUE : FALSE);
  if (FAILED(result))
    return result;
  result = settings->put_AreHostObjectsAllowed(FALSE);
  if (FAILED(result))
    return result;
  result = settings->put_IsWebMessageEnabled(TRUE);
  if (FAILED(result))
    return result;
  // alert/confirm/prompt/beforeunload nativos: ningún documento (ni siquiera el
  // propio) puede abrir un diálogo modal del sistema con texto de la página.
  result = settings->put_AreDefaultScriptDialogsEnabled(FALSE);
  if (FAILED(result))
    return result;
  result = settings->put_IsBuiltInErrorPageEnabled(FALSE);
  if (FAILED(result))
    return result;
  return settings->put_AreDefaultContextMenusEnabled(FALSE);
}

// La cabina no necesita cámara, micrófono, geolocalización, portapapeles ni
// notificaciones del navegador: todo PermissionRequested se deniega.
template <class Args> inline HRESULT DenyPermission(Args *args) {
  if (!args)
    return E_POINTER;
  return args->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY);
}

// La cabina escribe archivos sólo por el puente confinado. Una descarga del
// navegador se cancela y se marca como tratada para que no salga su interfaz.
template <class Args> inline HRESULT CancelDownload(Args *args) {
  if (!args)
    return E_POINTER;
  const HRESULT cancelled = args->put_Cancel(TRUE);
  if (FAILED(cancelled))
    return cancelled;
  return args->put_Handled(TRUE);
}

} // namespace webview_policy
} // namespace beats
#endif
