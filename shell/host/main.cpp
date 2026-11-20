#include "app_windows.hpp"
#include "bridge.hpp"
#include "browser_bridge.hpp"
#include "browser_dispatch.hpp"
#include "consent_prompt.hpp"
#include "core_client.hpp"
#include "core_dispatch.hpp"
#include "document_manager.hpp"
#include "file_watcher.hpp"
#include "hunk_manager.hpp"
#include "lsp_client.hpp"
#include "notification_policy.hpp"
#include "preview_policy.hpp"
#include "project_search.hpp"
#include "pty_manager.hpp"
#include "remote_controller.hpp"
#include "update_apply.hpp"
#include "webview2_missing.hpp"
#include "webview_host.hpp"
#include "window.hpp"
#include <chrono>
#include <condition_variable>
#include <deque>
#include <iostream>
#include <memory>
#include <mutex>
#include <shlobj.h>
#include <thread>
#include <vector>
#include <windows.h>

// Respuesta del hilo del motor lista para publicarse en el WebView.
// lParam lleva un EngineResponse* del que el hilo de UI toma posesion.
#define WM_BEATS_ENGINE_RESPONSE (WM_APP + 43)
// Evento de difusion para TODAS las ventanas (E5.21): lo postea cualquier
// hilo (p.ej. el FileWatcher) a la cola de UI y el bucle lo repite
// en cada WebView via supervisor.Broadcast.
#define WM_BEATS_ENGINE_PUSH (WM_APP + 44)
#define WM_BEATS_NOTIFICATION (WM_APP + 46)
static_assert(beats::BrowserDispatch::Message != WM_APP + 42 &&
                  beats::BrowserDispatch::Message != WM_BEATS_ENGINE_RESPONSE &&
                  beats::BrowserDispatch::Message != WM_BEATS_ENGINE_PUSH &&
                  beats::BrowserDispatch::Message != WM_BEATS_NOTIFICATION &&
                  beats::BrowserDispatch::Message != beats::consent::kMessage &&
                  beats::BrowserDispatch::Message !=
                      beats::notifications::Callback,
              "browser dispatcher message collision");

// Mensajes privados de la cola principal. El bucle de mensajes intercepta los
// cinco primeros y hace `continue`; el de consentimiento tiene que llegar al
// WndProc (window.cpp), así que ninguno puede compartir valor con otro.
static_assert(beats::consent::kMessage != WM_APP + 42 &&
                  beats::consent::kMessage != WM_BEATS_ENGINE_RESPONSE &&
                  beats::consent::kMessage != WM_BEATS_ENGINE_PUSH &&
                  beats::consent::kMessage != WM_BEATS_NOTIFICATION &&
                  beats::consent::kMessage != beats::notifications::Callback,
              "consent::kMessage colisiona con un mensaje que consume el "
              "bucle principal");
static_assert(beats::notifications::Callback != WM_APP + 42 &&
                  beats::notifications::Callback != WM_BEATS_ENGINE_RESPONSE &&
                  beats::notifications::Callback != WM_BEATS_ENGINE_PUSH &&
                  beats::notifications::Callback != WM_BEATS_NOTIFICATION,
              "notifications::Callback colisiona con otro mensaje privado");

// Diagnostico de fallos nativos.
//
// Un fallo dentro de devagents_core.dll mataba el proceso sin dejar rastro: ni
// mensaje, ni registro de sucesos, solo un codigo de salida. Este filtro anota
// codigo de excepcion, direccion y modulo responsable antes de morir, que es lo
// minimo para poder localizar el problema.
static LONG WINAPI BeatsCrashFilter(EXCEPTION_POINTERS *info) {
  FILE *f = nullptr;
  if (fopen_s(&f, "C:\\tmp\\beats_crash.txt", "a") == 0 && f) {
    void *addr = info->ExceptionRecord->ExceptionAddress;
    fprintf(f, "EXCEPCION code=0x%08lX addr=%p\n",
            info->ExceptionRecord->ExceptionCode, addr);

    HMODULE mod = nullptr;
    if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                               GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCWSTR)addr, &mod) &&
        mod) {
      wchar_t name[MAX_PATH] = {};
      GetModuleFileNameW(mod, name, MAX_PATH);
      fprintf(f, "  modulo=%ls base=%p offset=0x%llX\n", name, (void *)mod,
              (unsigned long long)((char *)addr - (char *)mod));
    }
    if (info->ExceptionRecord->ExceptionCode == EXCEPTION_ACCESS_VIOLATION &&
        info->ExceptionRecord->NumberParameters >= 2) {
      fprintf(f, "  acceso %s en %p\n",
              info->ExceptionRecord->ExceptionInformation[0] ? "de escritura"
                                                             : "de lectura",
              (void *)info->ExceptionRecord->ExceptionInformation[1]);
    }

    // Pila del hilo que revienta.
    //
    // Con una sola direccion se sabe QUE funcion fallo pero no quien la llamo,
    // y en un fallo de concurrencia eso es justo el dato que hace falta. Se
    // desenrolla con RtlVirtualUnwind, que es lo que hay disponible en x64 sin
    // arrastrar dbghelp, y se anota modulo + desplazamiento de cada marco para
    // poder resolverlo despues contra el .pdb con llvm-symbolizer.
#if defined(_M_X64) || defined(__x86_64__)
    CONTEXT ctx = *info->ContextRecord;
    fprintf(f, "  pila:\n");
    for (int frame = 0; frame < 24; ++frame) {
      DWORD64 imageBase = 0;
      PRUNTIME_FUNCTION rf = RtlLookupFunctionEntry(ctx.Rip, &imageBase, NULL);
      HMODULE frameMod = nullptr;
      wchar_t frameName[MAX_PATH] = L"?";
      if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                 GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                             (LPCWSTR)ctx.Rip, &frameMod) &&
          frameMod) {
        GetModuleFileNameW(frameMod, frameName, MAX_PATH);
      }
      const wchar_t *shortName = wcsrchr(frameName, L'\\');
      fprintf(f, "    #%02d %ls+0x%llX\n", frame,
              shortName ? shortName + 1 : frameName,
              frameMod ? (unsigned long long)(ctx.Rip - (DWORD64)frameMod) : 0);
      if (!rf)
        break; // Marco hoja sin tabla de desenrollado: no se puede seguir.
      PVOID handlerData = nullptr;
      ULONG64 establisher = 0;
      RtlVirtualUnwind(UNW_FLAG_NHANDLER, imageBase, ctx.Rip, rf, &ctx,
                       &handlerData, &establisher, NULL);
      if (!ctx.Rip)
        break;
    }
#endif
    fclose(f);
  }
  return EXCEPTION_CONTINUE_SEARCH;
}

// Entrega una respuesta al WebView y, si no se puede, avisa igualmente.
//
// PostWebMessageAsJson valida el documento: si un handler devuelve JSON mal
// formado (una ruta de Windows sin escapar basta), la llamada falla y NO SE
// ENTREGA NADA. El WebUI se queda con la promesa pendiente para siempre y el
// panel afectado congelado en su mensaje de carga, sin un error en ningun
// sitio. Aqui se rescata el `id` de la peticion y se responde con un error
// bien formado, que es lo que permite que el fallo se vea.
static void PostOrReportFailure(beats::WebViewHost &host,
                                const std::wstring &payload) {
  if (host.PostMessageJson(payload))
    return;

  size_t idPos = payload.find(L"\"id\":");
  long id = 0;
  if (idPos != std::wstring::npos) {
    id = wcstol(payload.c_str() + idPos + 5, nullptr, 10);
  }
  std::wstring fallback =
      L"{\"id\":" + std::to_wstring(id) +
      L",\"error\":\"El motor devolvio una respuesta que no "
      L"se pudo entregar (JSON invalido).\"}";
  host.PostMessageJson(fallback);

  FILE *f = nullptr;
  if (fopen_s(&f, "C:\\tmp\\beats_webview_debug.log", "a") == 0 && f) {
    fprintf(f, "[PostMessageJson] RECHAZADO id=%ld len=%zu\n", id,
            payload.size());
    fclose(f);
  }
}

// (9-nov): como cualquier IDE, la cabina reabre la ultima carpeta
// elegida en el dialogo nativo. El archivo lo escribe SOLO codigo nativo tras
// AuthorizeWorkspaceRoot (dialog.pickWorkspace); JS no puede escribirlo ni
// conceder una carpeta. Se usa solo si el proceso arranca desde la carpeta del
// propio programa o desde una ruta amplia (perfil, Windows, unidad): lanzado
// desde una carpeta concreta (una terminal en un proyecto), manda esa carpeta.
static std::wstring LastWorkspaceFile(const std::wstring &dataDir) {
  return dataDir.empty() ? std::wstring() : dataDir + L"\\last_workspace.txt";
}

static void SaveLastWorkspace(const std::wstring &dataDir,
                              const std::wstring &path) {
  const std::wstring file = LastWorkspaceFile(dataDir);
  if (file.empty() || path.empty() || path.size() > 32000)
    return;
  HANDLE h = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                         FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE)
    return;
  DWORD written = 0;
  WriteFile(h, path.data(), static_cast<DWORD>(path.size() * sizeof(wchar_t)),
            &written, nullptr);
  CloseHandle(h);
}

static std::wstring LoadLastWorkspace(const std::wstring &dataDir) {
  const std::wstring file = LastWorkspaceFile(dataDir);
  if (file.empty())
    return {};
  HANDLE h = CreateFileW(file.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                         OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE)
    return {};
  std::wstring out(4096, L'\0');
  DWORD read = 0;
  const BOOL ok =
      ReadFile(h, out.data(), static_cast<DWORD>(out.size() * sizeof(wchar_t)),
               &read, nullptr);
  CloseHandle(h);
  if (!ok || read == 0 || read % sizeof(wchar_t) != 0 ||
      read >= out.size() * sizeof(wchar_t))
    return {};
  out.resize(read / sizeof(wchar_t));
  for (wchar_t c : out)
    if (c < 32)
      return {};
  const DWORD attributes = GetFileAttributesW(out.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      !(attributes & FILE_ATTRIBUTE_DIRECTORY) ||
      (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
    return {};
  return out;
}

static std::wstring ExecutableDirectory() {
  wchar_t path[MAX_PATH * 4];
  const DWORD n = GetModuleFileNameW(nullptr, path, MAX_PATH * 4);
  if (!n || n >= MAX_PATH * 4)
    return {};
  std::wstring dir(path, n);
  const size_t slash = dir.find_last_of(L"\\/");
  return slash == std::wstring::npos ? std::wstring() : dir.substr(0, slash);
}

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR pCmdLine,
                   int nCmdShow) {
  SetUnhandledExceptionFilter(BeatsCrashFilter);
  // Initialize OLE / COM STA for WebView2
  OleInitialize(NULL);

  // --- A donde escriben stdout y stderr -------------------------------------
  //
  // El ORDEN de estas comprobaciones importa, y equivocarlo dejo ciegos a todos
  // los arneses del proyecto durante meses.
  //
  // Este binario es de subsistema Windows, asi que no trae consola propia. Hay
  // tres situaciones y solo una respuesta correcta para cada una:
  //
  //  1. El padre nos dio tuberias (ProcessStartInfo con RedirectStandardOutput,
  //     `cmd > fichero`, `2>&1`...). Los descriptores heredados YA son validos:
  //     no hay que tocar nada. Antes se llamaba a AttachConsole PRIMERO, que en
  //     este caso tiene exito porque el hijo hereda la consola del padre, y el
  //     freopen_s a CONOUT$ acto seguido DESCARTABA la tuberia heredada. El
  //     padre leia entonces una cadena vacia, de modo que `prueba_puente.ps1`
  //     escribia su bloque "SALIDA VERBATIM DEL PUENTE C++" en blanco y sus
  //     criterios se evaluaban contra la nada.
  //  2. Nos lanzaron desde una consola sin redirigir: ahi si conviene
  //     engancharse a la del padre para que el usuario vea la salida.
  //  3. Nadie nos dio nada (doble clic, `start`): a NUL, o la CRT falla al
  //     escribir sobre descriptores invalidos.
  //
  // Un handle nulo o INVALID_HANDLE_VALUE significa "no me dieron nada"; el
  // resto (tuberia, fichero o consola) es un destino valido que se respeta.
  {
    HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
    HANDLE hErr = GetStdHandle(STD_ERROR_HANDLE);
    const bool outRedirected =
        (hOut != nullptr && hOut != INVALID_HANDLE_VALUE);
    const bool errRedirected =
        (hErr != nullptr && hErr != INVALID_HANDLE_VALUE);

    // QA-A H17: freopen_s puede fallar y antes no se miraba; la CRT quedaba
    // escribiendo sobre un descriptor invalido. Si la consola del padre no se
    // puede abrir se cae a NUL, y si tampoco, se deja constancia en el
    // depurador: no hay consola donde decirlo.
    const auto reopen = [](const char *target, FILE *stream, const char *name) {
      FILE *reopened = nullptr;
      if (freopen_s(&reopened, target, "w", stream) == 0)
        return;
      std::string note = std::string("DevAgents: no se pudo redirigir ") +
                         name + " a " + target;
      if (std::string(target) != "NUL" &&
          freopen_s(&reopened, "NUL", "w", stream) == 0) {
        note += "; se redirige a NUL\n";
        OutputDebugStringA(note.c_str());
        return;
      }
      note += "; queda sin destino\n";
      OutputDebugStringA(note.c_str());
    };
    if (!outRedirected || !errRedirected) {
      if (AttachConsole(ATTACH_PARENT_PROCESS)) {
        if (!outRedirected)
          reopen("CONOUT$", stdout, "stdout");
        if (!errRedirected)
          reopen("CONOUT$", stderr, "stderr");
      } else {
        // Silenciar SOLO lo que no tiene destino. Redirigir a NUL de forma
        // incondicional se tragaba tambien los panics del motor: quedaba un
        // codigo de salida 3 sin una linea que lo explicase.
        if (!outRedirected)
          reopen("NUL", stdout, "stdout");
        if (!errRedirected)
          reopen("NUL", stderr, "stderr");
      }
    }
  }

  // Enable Per-Monitor DPI Aware V2
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

#ifndef NDEBUG
  const char *devToolsEnv = std::getenv("DEVAGENTS_DEVTOOLS_PORT");
  if (!devToolsEnv || std::string(devToolsEnv) == "") {
    devToolsEnv = std::getenv("BEATS_DEVTOOLS_PORT");
  }
  if (devToolsEnv && std::string(devToolsEnv) != "") {
    std::string portStr(devToolsEnv);
    int wlen = MultiByteToWideChar(CP_UTF8, 0, portStr.c_str(),
                                   (int)portStr.size(), NULL, 0);
    if (wlen > 0) {
      std::wstring wport(wlen, 0);
      MultiByteToWideChar(CP_UTF8, 0, portStr.c_str(), (int)portStr.size(),
                          &wport[0], wlen);
      // E3.39-D: sin `--remote-allow-origins=*` — con el comodín cualquier
      // origen podía abrir un WebSocket CDP al WebView (verificado con
      // Origin https://evil.example.com). Los drivers propios no envían
      // Origin y Chromium los deja pasar sin el flag.
      std::wstring devArg = L"--remote-debugging-port=" + wport;
      // WebViewHost passes this through environment options for its OWN
      // profile. A process-wide override would contaminate the browser panel.
      OutputDebugStringW(devArg.c_str());
    }
  }

#endif
  std::string cmdStr = pCmdLine ? pCmdLine : "";
#ifndef NDEBUG
  // Arnés de desarrollo: instancia el motor real y escribe en su catálogo.
  // No existe en Release (tools/check_webview_release.ps1 lo comprueba).
  if (cmdStr.find("--test-bridge") != std::string::npos) {
    beats::CoreClient coreClient;
    coreClient.StartCoreProcess();
    beats::DocumentManager docMgr;
    beats::FileWatcher fileWatcher;
    beats::ProjectSearch projectSearch(docMgr);
    beats::HunkManager hunkMgr(docMgr);
    beats::PtyManager ptyMgr;
    beats::LspClient lspClient;
    beats::Bridge bridge;
    bridge.BindServices(&docMgr, &fileWatcher, &projectSearch, &hunkMgr,
                        &ptyMgr, &lspClient, &coreClient);

    char cwdBuf[MAX_PATH];
    GetCurrentDirectoryA(MAX_PATH, cwdBuf);
    std::string cwd(cwdBuf);

    std::string escapedCwd;
    for (char c : cwd) {
      if (c == '\\')
        escapedCwd += "\\\\";
      else
        escapedCwd += c;
    }

    std::vector<std::pair<std::string, std::string>> tests = {
        {"init", "{\"id\":1,\"kind\":\"init\",\"payload\":{}}"},
        {"ping",
         "{\"id\":2,\"kind\":\"ping\",\"payload\":{\"ping\":\"test\"}}"},
        {"doc.open", "{\"id\":3,\"kind\":\"doc.open\",\"payload\":{\"path\":"
                     "\"C:\\\\tmp\\\\beats_test_document.txt\"}}"},
        {"doc.save",
         "{\"id\":4,\"kind\":\"doc.save\",\"payload\":{\"path\":\"C:"
         "\\\\tmp\\\\beats_test_document.txt\",\"content\":\"CONTENIDO "
         "MODIFICADO POR PUENTE C++ IPC VERBATIM\",\"force\":true}}"},
        {"fs.watch",
         "{\"id\":5,\"kind\":\"fs.watch\",\"payload\":{\"path\":\"" +
             escapedCwd + "\"}}"},
        {"fs.unwatch",
         "{\"id\":6,\"kind\":\"fs.unwatch\",\"payload\":{\"path\":\"" +
             escapedCwd + "\"}}"},
        {"search.query",
         "{\"id\":7,\"kind\":\"search.query\",\"payload\":{\"query\":"
         "\"devagents\","
         "\"rootDir\":\"" +
             escapedCwd +
             "\\\\core\",\"isRegex\":false,\"caseSensitive\":false}}"},
        {"hunk.accept",
         "{\"id\":9,\"kind\":\"hunk.accept\",\"payload\":{\"path\":\"C:"
         "\\\\tmp\\\\beats_test_document.txt\",\"hunkId\":1,"
         "\"originalContent\":\"CONTENIDO MODIFICADO POR PUENTE C++ IPC "
         "VERBATIM\",\"newContent\":\"CONTENIDO MODIFICADO POR HUNK\"}}"},
        {"hunk.reject",
         "{\"id\":10,\"kind\":\"hunk.reject\",\"payload\":{\"path\":\"C:"
         "\\\\tmp\\\\beats_test_document.txt\",\"hunkId\":1,"
         "\"originalContent\":\"CONTENIDO MODIFICADO POR PUENTE C++ IPC "
         "VERBATIM\",\"newContent\":\"CONTENIDO MODIFICADO POR HUNK\"}}"},
        {"pty.spawn", "{\"id\":11,\"kind\":\"pty.spawn\",\"payload\":{"
                      "\"shellPath\":\"cmd.exe\",\"workingDir\":\"" +
                          escapedCwd + "\"}}"},
        {"pty.write", "{\"id\":12,\"kind\":\"pty.write\",\"payload\":{"
                      "\"terminalId\":1,\"data\":\"echo test\\r\\n\"}}"},
        // pty.read es lo que faltaba para que la terminal fuese usable: se
        // podia crear y escribir, pero no leer. Se pide DESPUES de escribir y
        // con una espera previa (ver el bucle), porque la salida de cmd.exe
        // tarda unas decenas de milisegundos en llegar al scrollback.
        {"pty.read",
         "{\"id\":40,\"kind\":\"pty.read\",\"payload\":{\"terminalId\":1,"
         "\"since\":0}}"},
        {"pty.kill",
         "{\"id\":13,\"kind\":\"pty.kill\",\"payload\":{\"terminalId\":1}}"},
        {"lsp.request",
         "{\"id\":14,\"kind\":\"lsp.request\",\"payload\":{\"serverCmd\":\"\","
         "\"method\":\"initialize\",\"params\":\"{}\",\"requestId\":1}}"},
        {"core.status", "{\"id\":15,\"kind\":\"core.status\",\"payload\":{}}"},
        // core.screenshot: da_capture_screenshot estuvo exportada en el .def y
        // sin resolver ni invocar por nadie. Entra al arnes para que un export
        // huerfano vuelva a notarse: si el handler o el Resolve desaparecen, la
        // respuesta deja de traer "path" y se ve aqui.
        {"core.screenshot",
         "{\"id\":70,\"kind\":\"core.screenshot\",\"payload\":{}}"},
        // Superficie agentica: verifica que la cabina alcanza el cerebro del
        // motor, no solo el editor y la terminal.
        {"fs.list", "{\"id\":16,\"kind\":\"fs.list\",\"payload\":{\"path\":\"" +
                        escapedCwd + "\"}}"},
        {"core.providers.list",
         "{\"id\":17,\"kind\":\"core.providers.list\",\"payload\":{}}"},
        {"core.keys.list",
         "{\"id\":18,\"kind\":\"core.keys.list\",\"payload\":{}}"},
        {"core.models.list",
         "{\"id\":19,\"kind\":\"core.models.list\",\"payload\":{}}"},
        {"core.catalog.info",
         "{\"id\":20,\"kind\":\"core.catalog.info\",\"payload\":{}}"},
        {"core.governance.get",
         "{\"id\":21,\"kind\":\"core.governance.get\",\"payload\":{}}"},
        {"core.plan.getModel",
         "{\"id\":22,\"kind\":\"core.plan.getModel\",\"payload\":{}}"},
        {"core.sessions.list",
         "{\"id\":23,\"kind\":\"core.sessions.list\",\"payload\":{}}"},
        {"core.health", "{\"id\":24,\"kind\":\"core.health\",\"payload\":{}}"},
        {"core.ledger", "{\"id\":25,\"kind\":\"core.ledger\",\"payload\":{}}"},
        {"core.specialists",
         "{\"id\":26,\"kind\":\"core.specialists\",\"payload\":{}}"},
        {"core.mcp.status",
         "{\"id\":27,\"kind\":\"core.mcp.status\",\"payload\":{}}"},
        // Ciclo real de credenciales: dos claves sobre el MISMO proveedor
        // (multi-cuenta, que es lo que permite al motor rotar ante 429),
        // comprobacion de que aparecen listadas y borrado para no dejar
        // residuos en el catalogo del usuario.
        {"core.keys.add(Gemini/1)",
         "{\"id\":30,\"kind\":\"core.keys.add\",\"payload\":{\"provider\":"
         "\"Gemini\",\"label\":\"HARNESS_01\",\"key\":\"clave-de-prueba-no-"
         "valida-01\"}}"},
        {"core.keys.add(Gemini/2)",
         "{\"id\":31,\"kind\":\"core.keys.add\",\"payload\":{\"provider\":"
         "\"Gemini\",\"label\":\"HARNESS_02\",\"key\":\"clave-de-prueba-no-"
         "valida-02\"}}"},
        {"core.keys.add(Claude)",
         "{\"id\":32,\"kind\":\"core.keys.add\",\"payload\":{\"provider\":"
         "\"Claude\",\"label\":\"HARNESS_ANTHROPIC\",\"key\":\"clave-de-"
         "prueba-no-valida-03\"}}"},
        {"core.keys.list(tras alta)",
         "{\"id\":33,\"kind\":\"core.keys.list\",\"payload\":{}}"},
        {"core.status(tras alta)",
         "{\"id\":34,\"kind\":\"core.status\",\"payload\":{}}"},
        // PELIGRO HISTORICO: aqui iba `"label":""`, y una etiqueta vacia NO
        // significa "la que acabo de crear", sino COMODIN: el motor borro las
        // TRES claves reales de Gemini del usuario junto con las del arnes.
        // Cada borrado nombra ahora su etiqueta exacta, y nunca se pasa "".
        {"core.keys.remove(HARNESS_01)",
         "{\"id\":35,\"kind\":\"core.keys.remove\",\"payload\":{\"provider\":"
         "\"Gemini\",\"label\":\"HARNESS_01\"}}"},
        {"core.keys.remove(HARNESS_02)",
         "{\"id\":351,\"kind\":\"core.keys.remove\",\"payload\":{\"provider\":"
         "\"Gemini\",\"label\":\"HARNESS_02\"}}"},
        {"core.keys.remove(Claude)",
         "{\"id\":36,\"kind\":\"core.keys.remove\",\"payload\":{\"provider\":"
         "\"Claude\",\"label\":\"HARNESS_ANTHROPIC\"}}"},
        {"core.keys.list(tras borrado)",
         "{\"id\":37,\"kind\":\"core.keys.list\",\"payload\":{}}"},
        // El sondeo activo esta bloqueado en el puente porque aborta el
        // proceso (ver core.health.probe en bridge.cpp). Se comprueba que el
        // bloqueo responde con error en vez de tumbar la cabina.
        // Estuvo bloqueado porque abortaba el proceso. Si el abort vuelve, el
        // arnes muere AQUI con codigo 3 y las lineas siguientes no se imprimen:
        // esa ausencia es la senal.
        {"core.health.probe",
         "{\"id\":38,\"kind\":\"core.health.probe\",\"payload\":{\"maxModels\":"
         "2}}"},
        {"core.health(pasivo)",
         "{\"id\":39,\"kind\":\"core.health\",\"payload\":{}}"},
        // Las tres piezas de nivel 1 que quedaron sin ejercitar: permisos por
        // herramienta, tierlist del router y resumen de evolucion.
        // El motor recibe la politica como una CADENA JSON dentro de
        // `configJson`, no como campos sueltos del payload; es lo que
        // construye CoreApi.setPermissions en core_api.ts.
        {"core.permissions.set",
         "{\"id\":41,\"kind\":\"core.permissions.set\",\"payload\":{"
         "\"configJson\":\"{\\\"mode\\\":\\\"normal\\\",\\\"allow\\\":"
         "[\\\"read_file\\\"],\\\"deny\\\":[\\\"run_command\\\"]}\"}}"},
        {"core.model.scores",
         "{\"id\":42,\"kind\":\"core.model.scores\",\"payload\":{}}"},
        {"core.evolution",
         "{\"id\":43,\"kind\":\"core.evolution\",\"payload\":{}}"},
        // Descubrimiento de modelos: es lo que deberia poblar el catalogo tras
        // dar de alta una clave (reporte R4 del usuario). No recibe proveedor;
        // el motor recorre todos los que tengan credencial.
        {"core.models.discover",
         "{\"id\":44,\"kind\":\"core.models.discover\",\"payload\":{}}"},
        // Punto de control sobre git. Solo se crea: restaurar aqui reescribiria
        // el arbol de trabajo del propio repositorio en mitad de una prueba.
        {"checkpoint.create",
         "{\"id\":45,\"kind\":\"checkpoint.create\",\"payload\":{\"root\":\"" +
             escapedCwd + "\"}}"},
        // Hooks de ciclo de vida. Se configuran DESACTIVADOS a proposito: el
        // arnes no debe dejar comandos enganchados al motor tras terminar.
        {"core.hooks.set",
         "{\"id\":46,\"kind\":\"core.hooks.set\",\"payload\":{\"configJson\":"
         "\"{\\\"enabled\\\":false,\\\"postEdit\\\":\\\"\\\"}\"}}"},
        {"core.skills", "{\"id\":47,\"kind\":\"core.skills\",\"payload\":{}}"},
        {"core.memory", "{\"id\":48,\"kind\":\"core.memory\",\"payload\":{"
                        "\"project\":\"default\"}}"},
        // Comodin de borrado de claves: debe RECHAZARSE sin allowAll.
        {"core.keys.remove(sin label, debe fallar)",
         "{\"id\":49,\"kind\":\"core.keys.remove\",\"payload\":{\"provider\":"
         "\"Gemini\"}}"},
        // Favorito elegido por el usuario: marcar y desmarcar, para no dejar el
        // catalogo del usuario alterado por una prueba.
        {"core.model.setFavorite(on)",
         "{\"id\":50,\"kind\":\"core.model.setFavorite\",\"payload\":{"
         "\"provider\":\"OpenCode\",\"model\":\"claude-haiku-4-5\","
         "\"favorite\":true}}"},
        // Lectura INTERMEDIA: prueba que el favorito se escribio de verdad en
        // catalog.db, no solo que el puente respondio ok.
        {"core.models.list(tras marcar favorito)",
         "{\"id\":501,\"kind\":\"core.models.list\",\"payload\":{}}"},
        {"core.model.setFavorite(off)",
         "{\"id\":51,\"kind\":\"core.model.setFavorite\",\"payload\":{"
         "\"provider\":\"OpenCode\",\"model\":\"claude-haiku-4-5\","
         "\"favorite\":false}}"},
        // Era "core.mounts", un handler duplicado de core.mounts.list que se
        // retiro al limpiar P10. Sin este cambio el arnes pedia un kind que ya
        // no existe.
        {"core.mounts.list",
         "{\"id\":52,\"kind\":\"core.mounts.list\",\"payload\":{}}"},

        // --- Spaces -----------------------------------------------------
        //
        // Van al FINAL y detras de un cambio de workspace a proposito.
        // `createSpace` lanza `git worktree add` sobre la raiz del workspace:
        // si esa raiz cae dentro de este repositorio, el arnes crearia una
        // RAMA de verdad y un worktree en el repositorio del usuario. Apuntando
        // a un directorio inexistente de C:\tmp, `git rev-parse` falla, se
        // entra en modo degradado y no se toca ningun repositorio.
        //
        // Lo que esto demuestra es la cadena puente -> API C -> SQLite. La
        // creacion real del worktree de git NO queda cubierta aqui; eso vive
        // en los tests de core/src/spaces.zig, que tampoco usan un repositorio
        // git. Es un hueco declarado, no una prueba que se de por hecha.
        {"core.workspace.set(temporal para spaces)",
         "{\"id\":71,\"kind\":\"core.workspace.set\",\"payload\":{\"path\":\"C:"
         "\\\\tmp\\\\beats_spaces_harness\"}}"},
        {"core.space.create",
         "{\"id\":72,\"kind\":\"core.space.create\",\"payload\":{"
         "\"projectId\":\"arnes-puente\",\"name\":\"space-de-prueba\","
         "\"kind\":\"order\"}}"},
        // El listado tiene que TRAER el space recien creado. Comprobar solo que
        // responde no valdria: una lista vacia es tambien lo que devuelve un
        // motor que no hace nada.
        {"core.spaces.list",
         "{\"id\":73,\"kind\":\"core.spaces.list\",\"payload\":{"
         "\"projectId\":\"arnes-puente\"}}"},
        // Podar NO debe llevarse un space activo: aqui tiene que salir 0.
        {"core.spaces.prune(space activo, no debe podar)",
         "{\"id\":74,\"kind\":\"core.spaces.prune\",\"payload\":{"
         "\"projectId\":\"arnes-puente\"}}"},
        // kind invalido: la columna lleva un CHECK, asi que esto debe dar error
        // en vez de caer a un valor por defecto.
        {"core.space.create(kind invalido, debe fallar)",
         "{\"id\":75,\"kind\":\"core.space.create\",\"payload\":{"
         "\"projectId\":\"arnes-puente\",\"name\":\"no-deberia-existir\","
         "\"kind\":\"inventado\"}}"},

        // --- Plugins ----------------------------------------------------
        //
        // El listado tiene que responder aunque no haya ninguno instalado, y
        // da_plugins_dir tiene que decir DONDE se instalan: sin esa ruta el
        // usuario no sabe adonde copiar la carpeta.
        {"core.plugins.dir",
         "{\"id\":76,\"kind\":\"core.plugins.dir\",\"payload\":{}}"},
        {"core.plugins.list",
         "{\"id\":77,\"kind\":\"core.plugins.list\",\"payload\":{}}"},
        // Salvaguarda de rutas: una carpeta con separadores o `..` sacaria la
        // carga fuera del directorio de plugins. Un plugin es codigo nativo que
        // entra en ESTE proceso, asi que debe rechazarse.
        {"core.plugin.trust(ruta de escape, debe fallar)",
         "{\"id\":78,\"kind\":\"core.plugin.trust\",\"payload\":{\"folder\":\""
         "..\\\\..\\\\windows\\\\system32\"}}"},
        {"core.plugin.trust(inexistente, debe fallar)",
         "{\"id\":79,\"kind\":\"core.plugin.trust\",\"payload\":{\"folder\":"
         "\"no-existe-este-plugin\"}}"},
        // D4: llamada directa al modelo, sin planificador. Sale a la red, asi
        // que con la cuota agotada devolvera {"ok":false,...} — y eso TAMBIEN
        // es una respuesta valida: lo que se comprueba aqui es que el handler
        // existe, resuelve el simbolo y contesta un JSON con forma, no que haya
        // cuota. Un fallo de red no puede hacer fallar la prueba del cableado.
        {"core.complete",
         "{\"id\":80,\"kind\":\"core.complete\",\"payload\":{\"prompt\":"
         "\"Responde exactamente: ok\",\"system\":\"Responde en una palabra.\"}"
         "}"}};

    // La cabina es un binario GUI: stdout se pierde salvo que exista consola
    // padre. El informe se escribe tambien a disco para poder auditarlo.
    FILE *report = nullptr;
    fopen_s(&report, "C:\\tmp\\beats_bridge_test.txt", "w");

    for (const auto &t : tests) {
      if (t.first == "pty.read")
        Sleep(700);
      std::string resp = bridge.HandleMessage(t.second);
      std::cout << "--- [KIND: " << t.first << "] ---\n";
      std::cout << "PETICION  : " << t.second << "\n";
      std::cout << "RESPUESTA : " << resp << "\n\n" << std::flush;
      if (report) {
        fprintf(report,
                "--- [KIND: %s] ---\nPETICION  : %s\nRESPUESTA : %s\n\n",
                t.first.c_str(), t.second.c_str(), resp.c_str());
      }
    }
    if (report)
      fclose(report);

    coreClient.StopCoreProcess();
    return 0;
  }
#endif

  // ---------------------------------------------------------------------
  // E5.21 — multiventana. Un supervisor registra todas las AppWindow; cada una
  // lleva su Window, su WebViewHost y su Bridge (enrutado propio), sobre los
  // servicios de proceso COMPARTIDOS. La revision de seguridad entre hilos de
  // cada servicio compartido queda documentada en docs/MULTIVENTANA.md.
  // ---------------------------------------------------------------------
  // Tanda 5 (F0.4): mutex con nombre del host vivo. El instalador lanzado con
  // /UPDATE espera a que desaparezca antes de tocar archivos
  // (tools/installer.iss). No se cierra: lo libera el sistema al terminar.
  if (!CreateMutexW(nullptr, FALSE, beats::update::kHostMutexName))
    std::cerr << "DevAgents: no se pudo crear el mutex del host (error "
              << GetLastError() << ")\n";

  beats::WindowSupervisor supervisor;
  beats::CoreClient coreClient;
  beats::BrowserDispatch::Backend browserBackend;
  browserBackend.attach = [&coreClient](const std::string &json) {
    return coreClient.CallJson(coreClient.Api().browser_host_attach_v1, json);
  };
  browserBackend.poll = [&coreClient](const std::string &capability) {
    return coreClient.CallJson(coreClient.Api().browser_host_poll_v1,
                               capability);
  };
  browserBackend.control = [&coreClient](const std::string &json) {
    return coreClient.CallJson(coreClient.Api().browser_control_v1, json);
  };
  browserBackend.resolveRoot = [&coreClient](long long order) {
    if (!coreClient.EngineReady() || !coreClient.Api().order_worktree_json)
      return beats::CoreResult{-1, "", "host_unavailable"};
    char *out = nullptr;
    auto result = coreClient.Wrap(coreClient.Api().order_worktree_json(
        coreClient.Handle(),
        reinterpret_cast<void *>(static_cast<uintptr_t>(order)), &out));
    result.json = coreClient.TakeString(out);
    return result;
  };
  browserBackend.complete = [&coreClient](const std::string &capability,
                                          const std::string &json) {
    if (!coreClient.EngineReady() || !coreClient.Api().browser_host_complete_v1)
      return beats::CoreResult{-1, "", "host_unavailable"};
    return coreClient.Wrap(coreClient.Api().browser_host_complete_v1(
        coreClient.Handle(), capability.c_str(), json.c_str()));
  };
  auto browserDispatch =
      std::make_shared<beats::BrowserDispatch>(std::move(browserBackend));
  const std::weak_ptr<beats::BrowserDispatch> browserWeak = browserDispatch;
  coreClient.SetBrowserStopHook([browserWeak] {
    if (auto dispatcher = browserWeak.lock())
      dispatcher->Stop();
  });
  supervisor.SetDestroyed([browserWeak](beats::AppWindow &aw) {
    if (auto dispatcher = browserWeak.lock())
      dispatcher->Detach(aw.hwnd);
  });
  beats::DocumentManager docMgr;
  // La ruta inicial pasa por la misma autorización que una selección nativa.
  wchar_t current[32768];
  const DWORD currentLength = GetCurrentDirectoryW(32768, current);
  std::wstring workspaceRoot = currentLength && currentLength < 32768
                                   ? std::wstring(current, currentLength)
                                   : std::wstring();
  if (beats::DocumentManager::IsInstallationDirectory(workspaceRoot) ||
      beats::DocumentManager::IsBroadStartupRoot(workspaceRoot))
    workspaceRoot = LoadLastWorkspace(coreClient.DataDirectory());
  const auto activateWorkspace = [&coreClient](const std::wstring &root,
                                               std::string &error) {
    return coreClient.SetWorkspaceRoot(root, error);
  };
  std::string workspaceError;
  if (!workspaceRoot.empty() &&
      !beats::DocumentManager::IsBroadStartupRoot(workspaceRoot))
    docMgr.AuthorizeWorkspaceRoot(workspaceRoot, workspaceError,
                                  activateWorkspace);
  if (!workspaceError.empty())
    OutputDebugStringA(("[Documents] " + workspaceError + "\n").c_str());
  beats::FileWatcher fileWatcher;
  beats::ProjectSearch projectSearch(docMgr);
  beats::HunkManager hunkMgr(docMgr);
  beats::PtyManager ptyMgr;
  beats::LspClient lspClient;

  // Junto al resto de datos de la aplicacion (claves, catalogo, perfil de
  // WebView2) en vez de en C:\tmp, que es un directorio que cualquiera limpia
  // y que no tiene por que existir en otro equipo. Se conserva C:\tmp como
  // ultimo recurso si no se puede resolver LOCALAPPDATA.
  std::wstring configPath = L"C:\\tmp\\beats_geometry.ini";
  std::wstring configDir;
  {
    configDir = coreClient.DataDirectory();
    if (!configDir.empty()) {
      configPath = configDir + L"\\window_geometry.ini";
    } else {
      OutputDebugStringW(L"DevAgents: no data directory; startup aborted\n");
      OleUninitialize();
      return 1;
    }
  }

  auto toWide = [](const std::string &s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), NULL, 0);
    std::wstring w(n, 0);
    if (n > 0) {
      MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
    }
    return w;
  };

  // Cada peticion conserva HWND + puente desde su encolado: un HWND reciclado
  // no puede ejecutar trabajo ni recibir respuestas de la ventana anterior.
  struct QueuedRequest {
    std::string json;
    HWND src = nullptr;
    std::function<void()> task = nullptr;
    std::shared_ptr<beats::Bridge> bridge;
  };
  struct EngineResponse {
    HWND src;
    std::shared_ptr<beats::Bridge> bridge;
    std::wstring json;
  };
  std::mutex queueMutex;
  std::condition_variable queueCv;
  std::deque<QueuedRequest> requestQueue;
  std::deque<QueuedRequest> slowQueue;
  std::condition_variable slowCv;
  // QA primerizo (11-nov): carril propio para descubrir agentes y modelos.
  // «Detectar agentes» lanza cada CLI para listar sus modelos (decenas de
  // segundos) y, en el carril lento compartido, core.git.status esperaba
  // detrás hasta agotar sus 60 s.
  std::deque<QueuedRequest> discoveryQueue;
  std::condition_variable discoveryCv;
  // Remate D7 (10-nov): carril propio para lo que pide autorización nativa
  // (beats::RequiresNativeConsent). El worker espera al diálogo sin plazo
  // mientras la persona decide; en el carril rápido eso dejaba parada toda
  // la cabina (estado, eventos de una orden en curso, otras ventanas) y las
  // peticiones de detrás caducaban a los 60 s de la cabina.
  std::deque<QueuedRequest> consentQueue;
  std::condition_variable consentCv;
  // B1e (11-nov): carril de los puntos de control (beats::IsCheckpointKind).
  // checkpoint.create va en cada envio de Directo y lanza git (~0,4 s, mas
  // con un arbol grande); en el hilo de la interfaz congelaba la ventana. Un
  // solo hilo los atiende en el orden en que llegan, asi que create y restore
  // nunca se cruzan, y no esperan detras de una llamada de red (carril lento)
  // ni de un dialogo de autorizacion (carril D7).
  std::deque<QueuedRequest> checkpointQueue;
  std::condition_variable checkpointCv;
  bool workerStop = false;
  auto enqueueCoreTask = [&](std::function<void()> task) {
    {
      std::lock_guard<std::mutex> lock(queueMutex);
      if (workerStop)
        return false;
      requestQueue.push_back({"", nullptr, std::move(task), nullptr});
    }
    queueCv.notify_one();
    return true;
  };

  auto esLenta = [](const std::string &kind) {
    static const char *kLentas[] = {
        "core.complete",
        "core.health.probe",
        "core.vision.probe",
        "core.mcp.connect",
        "core.mcp.call",
        "core.mcp.tools",
        "core.model.register",
        // da_web_search sale a Tavily/Brave/DuckDuckGo: sin esta línea corría
        // en el carril rápido y una búsqueda lenta congelaba la cola entera.
        "core.websearch",
        // (8-nov): la tarjeta Cambios valida el arbol entero del
        // proyecto antes de llamar a git (LockTree; ~4 s con 26 000 entradas,
        // hasta el tope de 100 000 en un arbol grande). En el carril rapido
        // congelaba la cabina entera; medido con muestreo de pila.
        "core.git.status",
        // (12-nov): sin diálogo nativo ya no van al carril D7;
        // validan el árbol y lanzan git como core.git.status.
        "core.git.commit",
        "core.git.init",
        "core.issues.list",
        "core.issues.read",
        "core.issues.prompt",
        "core.issues.comment",
        "core.order.fromIssue",
        // Monitor: leen catalog.db/runtime.db a sqlite3_step directo. En vacío
        // responden en ms, pero con un dispatch escribiendo eventos a la vez se
        // midieron >60 s (E2, wedge reproducible) y todo lo encolado detrás en
        // el carril rápido — status, eventos, órdenes — se congelaba con ellas.
        "core.ledger",
        "core.model.scores",
        "core.evolution",
        // Tanda 5: consulta diaria a GitHub y descarga del instalador.
        "core.update.check",
        "core.update.download",
    };
    for (const char *k : kLentas) {
      if (kind == k)
        return true;
    }
    // search.* re-lee el repo entero línea a línea (O(proyecto)): medido
    // >60 s en este repo, congelando status/monitor detrás. No es red
    // pero sí lento por construcción; al carril lento.
    return kind.rfind("search.", 0) == 0;
  };
  auto esDescubrimiento = [](const std::string &kind) {
    static const char *kDescubrimiento[] = {
        "core.models.discover",
        "core.external.agents",
        "core.external.refresh",
        "core.external.options.set",
        "core.inventory.refresh",
        "core.doctor",
        // Tanda 5: el estado y los ajustes del actualizador van con doctor;
        // check y download salen a GitHub y van al carril lento (kLentas).
        "core.update.state",
        "core.update.setEnabled",
        "core.update.applyOnExit",
    };
    for (const char *k : kDescubrimiento) {
      if (kind == k)
        return true;
    }
    return false;
  };

  // Traza opcional de la cola del motor: BEATS_TRACE_QUEUE=C:\ruta\log escribe
  // cada petición al entrar y al salir del worker. Sirvió para cazar el
  // cuelgue del carril rápido (un core.* se quedaba dentro y el resto esperaba
  // detrás sin síntoma visible).
  const char *tracePath = std::getenv("BEATS_TRACE_QUEUE");
  auto trace = [tracePath](const char *fase, const std::string &raw) {
    if (!tracePath)
      return;
    FILE *f = nullptr;
    if (fopen_s(&f, tracePath, "a") == 0 && f) {
      // Solo el kind: el payload puede llevar claves. ExtractKind lee el del
      // nivel superior — por substring se podía volcar una `"kind"` del
      // payload (que SÍ puede llevar texto del usuario) como si fuera el tipo.
      std::string kind = beats::Bridge::ExtractKind(raw);
      // Timestamp relativo al arranque del proceso: sin él no se distingue un
      // handler lento de una espera en cola (— wedge de ~70 s en frío).
      static const auto t0 = std::chrono::steady_clock::now();
      const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                          std::chrono::steady_clock::now() - t0)
                          .count();
      fprintf(f, "%lld %s %s\n", static_cast<long long>(ms), fase,
              kind.empty() ? "?" : kind.c_str());
      fflush(f);
      fclose(f);
    }
  };

  // Difusion a todas las ventanas: el sink del puente puede saltar desde el
  // hilo del FileWatcher, asi que siempre pasa por la cola de UI.
  beats::RemoteController remote(
      coreClient, [&](const std::string &request, HANDLE stop) {
        return beats::DispatchCoreCall(
            enqueueCoreTask,
            [&, request] {
              return coreClient.CallJson(coreClient.Api().remote_request_json,
                                         request);
            },
            stop);
      });
  std::mutex notificationMutex;
  std::deque<std::pair<long long, std::string>> notifications;
  long long balloonOrder = 0;
  long long observedOrder = 0;
  std::string balloonState;
  bool balloonSent = false;
  bool balloonFocused = false;
  // La cola pertenece al proceso, no a la principal que puede cerrar antes.
  const DWORD uiThreadId = GetCurrentThreadId();
  MSG queueInit = {};
  PeekMessageW(&queueInit, nullptr, 0, 0, PM_NOREMOVE);
  auto broadcastFromAnyThread = [uiThreadId,
                                 &toWide](const std::string &jsonMsg) {
    auto *payload = new std::wstring(toWide(jsonMsg));
    if (PostThreadMessageW(uiThreadId, WM_BEATS_ENGINE_PUSH, 0,
                           reinterpret_cast<LPARAM>(payload))) {
      return;
    }
    delete payload;
  };

  // Monta el WebView + bridge de una ventana recien creada. Va como callback
  // del supervisor porque window.open (puente) tambien la usa.
  std::wstring bundleDir = L"shell\\webui\\dist";
  bool devTools = false;
  std::wstring cmdArgsW;
  {
    wchar_t hostExePath[MAX_PATH];
    if (GetModuleFileNameW(NULL, hostExePath, MAX_PATH) != 0) {
      wchar_t *lastSlash = wcsrchr(hostExePath, L'\\');
      if (lastSlash) {
        std::wstring exeDir(hostExePath, lastSlash - hostExePath);
        std::wstring candidate0 = exeDir + L"\\dist";
        std::wstring candidate1 = exeDir + L"\\shell\\webui\\dist";
        std::wstring candidate2 = exeDir + L"\\..\\..\\shell\\webui\\dist";
        DWORD attr0 = GetFileAttributesW(candidate0.c_str());
        DWORD attr1 = GetFileAttributesW(candidate1.c_str());
        DWORD attr2 = GetFileAttributesW(candidate2.c_str());
        if (attr1 != INVALID_FILE_ATTRIBUTES &&
            (attr1 & FILE_ATTRIBUTE_DIRECTORY)) {
          bundleDir = candidate1;
        } else if (attr0 != INVALID_FILE_ATTRIBUTES &&
                   (attr0 & FILE_ATTRIBUTE_DIRECTORY)) {
          bundleDir = candidate0;
        } else if (attr2 != INVALID_FILE_ATTRIBUTES &&
                   (attr2 & FILE_ATTRIBUTE_DIRECTORY)) {
          bundleDir = candidate2;
        }
      }
    }
  }
  {
    // El bundle servido (origen de confianza) y el directorio del ejecutable
    // no se pueden escribir desde la cabina aunque cuelguen de una raíz
    // concedida: un guardado ahí cambiaría el JavaScript que se ejecutará.
    const auto denyDirectory = [&docMgr](const std::wstring &directory) {
      wchar_t full[32768];
      const DWORD length =
          GetFullPathNameW(directory.c_str(), 32768, full, nullptr);
      if (length && length < 32768)
        docMgr.DenyWritesBelow(std::wstring(full, length));
    };
    denyDirectory(bundleDir);
    wchar_t exePath[MAX_PATH];
    if (GetModuleFileNameW(NULL, exePath, MAX_PATH) != 0)
      if (wchar_t *slash = wcsrchr(exePath, L'\\')) {
        *slash = L'\0';
        denyDirectory(exePath);
      }
  }
#ifndef NDEBUG
  devTools = true;
  {
    int wsize = MultiByteToWideChar(CP_UTF8, 0, cmdStr.c_str(),
                                    (int)cmdStr.size(), NULL, 0);
    if (wsize > 0) {
      cmdArgsW.resize(wsize);
      MultiByteToWideChar(CP_UTF8, 0, cmdStr.c_str(), (int)cmdStr.size(),
                          &cmdArgsW[0], wsize);
    }
  }
#endif
  // Perfil de WebView2 ESTABLE, sin el PID en el nombre.
  //
  // Antes se creaba "WebView2Data_<pid>", es decir un perfil nuevo en cada
  // arranque: localStorage se estrenaba vacio cada vez, asi que el tema y las
  // preferencias del usuario se perdian siempre y quedaban carpetas huerfanas
  // acumulandose. WebView2 admite varios procesos compartiendo carpeta de
  // datos, de modo que un nombre fijo es correcto ademas de persistente.
  std::wstring customUserDataDir = configDir + L"\\WebView2Data";
  {
#ifndef NDEBUG
    // Con puerto de depuración el WebView arranca con otros argumentos, y
    // WebView2 NO deja compartir carpeta de datos entre entornos con opciones
    // distintas: la segunda cabina moría con 0x8007139F (medido el 22-09 con
    // la del propietario abierta). Además así las pruebas por CDP no tocan el
    // localStorage real del usuario (el tema 'nord' que dejaba).
    const char *dbgPort = std::getenv("DEVAGENTS_DEVTOOLS_PORT");
    if (!dbgPort || !*dbgPort)
      dbgPort = std::getenv("BEATS_DEVTOOLS_PORT");
    if (dbgPort && *dbgPort)
      customUserDataDir += L"-devtools";
#endif
  }

  supervisor.SetCreateWebView([&](beats::AppWindow &aw) -> bool {
    aw.browser.SetControlSink(
        [browserWeak, hwnd = aw.hwnd](const std::string &action,
                                      const std::string &tab) {
          if (auto dispatcher = browserWeak.lock())
            dispatcher->Control(hwnd, action, tab);
        });
    aw.webview.SetStartTime(aw.window.GetStartTime());
    // La query de navegacion (?ventana=..&vista=..) la puso quien pidio la
    // ventana via Create(..., navQuery) — aqui ya esta fijada.
    aw.window.SetResizeCallback([&aw](int width, int height) {
      aw.webview.Resize(width, height);
      aw.browser.Resize(width, height);
    });
    aw.window.SetMoveCallback([&aw]() { aw.webview.NotifyMoved(); });
    aw.window.SetCloseCallback([&supervisor, &docMgr](beats::Window &w) {
      beats::AppWindow *self = supervisor.ByHwnd(w.GetHandle());
      const bool isPrimary = self && self->primary;
      if (!isPrimary && supervisor.All().size() > 1)
        return true; // una secundaria cierra sin mas
      // La principal o la ultima ventana comprueban cambios sin guardar.
      // La pregunta es nativa — la WebUI puede
      // no estar respondiendo justo cuando el usuario quiere salir.
      auto dirty = docMgr.DirtyPaths();
      if (dirty.empty())
        return true;
      std::wstring msg = L"Hay " + std::to_wstring(dirty.size()) +
                         L" documento(s) sin guardar:\n\n";
      for (size_t i = 0; i < dirty.size() && i < 8; ++i)
        msg += dirty[i] + L"\n";
      if (dirty.size() > 8)
        msg += L"…\n";
      msg += L"\n¿Cerrar de todos modos?";
      int r = beats::themed::Show(w.GetHandle(), L"Cambios sin guardar", msg,
                                  beats::themed::Kind::warning,
                                  beats::themed::Buttons::yes_no, true,
                                  L"Cerrar", L"Cancelar");
      return r == IDYES;
    });
    aw.window.SetDestroyCallback([&supervisor, &configPath](beats::Window &w) {
      beats::AppWindow *self = supervisor.ByHwnd(w.GetHandle());
      if (self && self->primary && !w.SaveGeometry(configPath))
        OutputDebugStringW(
            L"DevAgents: no se pudo guardar geometria principal\n");
      if (self && supervisor.OnWindowDestroyed(*self))
        PostQuitMessage(0);
    });
    if (aw.vista == "browser") {
      aw.window.SetTitlebarHeight(0);
      std::string browserRoot;
      if (aw.navOrder > 0) {
        if (!coreClient.EngineReady() || !coreClient.Api().order_worktree_json)
          return false;
        char *out = nullptr;
        const int rc = coreClient.Api().order_worktree_json(
            coreClient.Handle(),
            reinterpret_cast<void *>(static_cast<uintptr_t>(aw.navOrder)),
            &out);
        const auto path =
            beats::GetStringProp(coreClient.TakeString(out), "path");
        browserRoot = path;
        std::string cause;
        if (rc != 0 ||
            !beats::Bridge::AuthorizeOrderWorktree(
                docMgr, beats::Bridge::IsSessionOrder(aw.navOrder), path,
                cause) ||
            !aw.browser.SetFixtureRoot(beats::preview::Wide(path)))
          return false;
      }
      if (!aw.browser.Open(aw.hwnd, configDir, true))
        return false;
      return aw.navOrder <= 0 ||
             browserDispatch->Attach(aw.hwnd, aw.navOrder, browserRoot);
    }
    if (aw.vista == "preview") {
      aw.window.SetTitlebarHeight(0);
      if (!coreClient.EngineReady() || !coreClient.Api().order_worktree_json) {
        beats::themed::Show(aw.hwnd, L"Vista previa",
                            L"La vista previa requiere el motor disponible.",
                            beats::themed::Kind::error,
                            beats::themed::Buttons::ok);
        return false;
      }
      char *out = nullptr;
      const int result = coreClient.Api().order_worktree_json(
          coreClient.Handle(),
          reinterpret_cast<void *>(static_cast<uintptr_t>(aw.navOrder)), &out);
      const std::string worktree = coreClient.TakeString(out);
      const std::string path = beats::GetStringProp(worktree, "path");
      if (result != 0 || path.empty() ||
          !aw.webview.ConfigurePreview(
              beats::preview::Wide(path), aw.navPath, aw.navOrder, aw.id,
              [&supervisor](const std::wstring &picked) {
                supervisor.Broadcast(picked);
              })) {
        const std::wstring error =
            result != 0 ? beats::preview::Wide(coreClient.LastEngineError())
                        : L"No se puede previsualizar: falta el HTML, la ruta "
                          L"es inválida o el árbol contiene enlaces, supera "
                          L"100000 entradas o 64 niveles.";
        beats::themed::Show(aw.hwnd, L"Vista previa rechazada", error,
                            beats::themed::Kind::error,
                            beats::themed::Buttons::ok);
        return false;
      }
      return aw.webview.Initialize(aw.hwnd, customUserDataDir, bundleDir,
                                   devTools, cmdArgsW);
    }
    aw.bridge->BindServices(&docMgr, &fileWatcher, &projectSearch, &hunkMgr,
                            &ptyMgr, &lspClient, &coreClient);
    aw.bridge->SetDialogOwner(aw.hwnd);
    aw.bridge->SetEventSink([broadcastFromAnyThread](const std::string &ev) {
      broadcastFromAnyThread(ev);
    });

    for (const std::string action : {"start", "stop", "status"}) {
      aw.bridge->RegisterHandler(
          "core.remote." + action,
          [&remote, action](const beats::BridgeMessage &msg) {
            beats::CoreResult result;
            if (action == "start")
              result = remote.Start(msg.payloadJson);
            else {
              if (action == "stop")
                remote.Stop();
              result = remote.Status();
            }
            if (!result.ok())
              return "{\"id\":" + std::to_string(msg.id) + ",\"error\":\"" +
                     beats::JsonEscapePublic(result.error) + "\"}";
            return "{\"id\":" + std::to_string(msg.id) +
                   ",\"status\":\"ok\",\"payload\":" + result.json + "}";
          });
    }
    aw.bridge->RegisterHandler(
        "notifications.status",
        [&observedOrder, &balloonState, &balloonSent,
         &balloonFocused](const beats::BridgeMessage &msg) {
          return "{\"id\":" + std::to_string(msg.id) +
                 ",\"status\":\"ok\",\"payload\":{\"order_id\":" +
                 std::to_string(observedOrder) + ",\"state\":\"" +
                 beats::JsonEscapePublic(balloonState) +
                 "\",\"sent\":" + (balloonSent ? "true" : "false") +
                 ",\"focused\":" + (balloonFocused ? "true" : "false") + "}}";
        });

    // Controles de ventana desde la titlebar del WebView. La barra de titulo
    // la dibuja el WebUI, asi que minimizar/maximizar/cerrar tienen que volver
    // al host: sin esto los botones existen pero no hacen nada. Con
    // multiventana van a SU ventana (puente propio de cada AppWindow).
    HWND hwnd = aw.hwnd;
    aw.bridge->RegisterHandler(
        "window.command", [hwnd](const beats::BridgeMessage &msg) {
          const std::string &p = msg.payloadJson;
          std::string reply =
              "{\"id\":" + std::to_string(msg.id) +
              ",\"status\":\"ok\",\"payload\":{\"applied\":true}}";
          if (p.find("\"drag\"") != std::string::npos) {
            ReleaseCapture();
            SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
          } else if (p.find("\"minimize\"") != std::string::npos) {
            ShowWindow(hwnd, SW_MINIMIZE);
          } else if (p.find("\"maximize\"") != std::string::npos) {
            WINDOWPLACEMENT wp = {sizeof(WINDOWPLACEMENT)};
            GetWindowPlacement(hwnd, &wp);
            ShowWindow(hwnd, wp.showCmd == SW_SHOWMAXIMIZED ? SW_RESTORE
                                                            : SW_SHOWMAXIMIZED);
          } else if (p.find("\"close\"") != std::string::npos) {
            PostMessageW(hwnd, WM_CLOSE, 0, 0);
          } else {
            return "{\"id\":" + std::to_string(msg.id) +
                   ",\"error\":\"Comando de ventana desconocido\"}";
          }
          return reply;
        });

    // E5.21 — ciclo de vida de ventanas secundarias, validado por
    // ParseOpenWindow (vista conocida + parametros requeridos).
    aw.bridge->RegisterHandler(
        "browser.panel.toggle", [&aw, &configDir, &coreClient, &browserDispatch,
                                 &docMgr](const beats::BridgeMessage &msg) {
          std::string orderPath;
          beats::preview::Value payload;
          // 10-nov (propietario: navegador «siempre que el agente lo
          // necesite»): `ensure:true` abre el panel si está oculto y lo
          // engancha a la orden, sin cerrarlo nunca. Lo pide la cabina cuando
          // un agente usa browser_*; sin `ensure` es el conmutador de siempre.
          bool ensure = false;
          bool valid = beats::preview::Parser(msg.payloadJson, false, true)
                           .Parse(payload) &&
                       payload.type == beats::preview::Value::Object &&
                       payload.object.size() <= 2;
          const auto orderIt = payload.object.find("order_id");
          const auto ensureIt = payload.object.find("ensure");
          if (valid) {
            for (const auto &kv : payload.object)
              valid = valid && (kv.first == "order_id" || kv.first == "ensure");
            if (ensureIt != payload.object.end()) {
              valid = valid &&
                      ensureIt->second.type == beats::preview::Value::Boolean;
              ensure = valid && ensureIt->second.number != 0;
            }
            if (orderIt != payload.object.end())
              valid =
                  valid &&
                  beats::preview::Number(payload, "order_id", 0, 2147483647) &&
                  std::floor(orderIt->second.number) == orderIt->second.number;
            valid = valid && (!ensure || orderIt != payload.object.end());
          }
          if (!valid)
            return "{\"id\":" + std::to_string(msg.id) +
                   ",\"error\":\"El panel no acepta destinos ni operaciones "
                   "del agente\"}";
          const long order = orderIt == payload.object.end()
                                 ? 0
                                 : static_cast<long>(orderIt->second.number);
          const bool visible = aw.browser.Visible();
          if (ensure && visible &&
              (order <= 0 || browserDispatch->AttachedOrder(aw.hwnd) == order))
            return "{\"id\":" + std::to_string(msg.id) +
                   ",\"status\":\"ok\",\"payload\":{}}";
          const bool attach = order > 0 && (!visible || ensure);
          if (attach) {
            if (!coreClient.EngineReady() ||
                !coreClient.Api().order_worktree_json)
              return "{\"id\":" + std::to_string(msg.id) +
                     ",\"error\":\"La página de la orden requiere el motor\"}";
            char *out = nullptr;
            const int rc = coreClient.Api().order_worktree_json(
                coreClient.Handle(),
                reinterpret_cast<void *>(static_cast<uintptr_t>(order)), &out);
            const auto path =
                beats::GetStringProp(coreClient.TakeString(out), "path");
            orderPath = path;
            std::string cause;
            if (rc != 0 ||
                !beats::Bridge::AuthorizeOrderWorktree(
                    docMgr, beats::Bridge::IsSessionOrder(order), path,
                    cause) ||
                !aw.browser.SetFixtureRoot(beats::preview::Wide(path)))
              return "{\"id\":" + std::to_string(msg.id) +
                     ",\"error\":\"Worktree de la orden no disponible o no "
                     "autorizado\"}";
          }
          if (visible && !ensure) {
            aw.browser.Hide();
            browserDispatch->Detach(aw.hwnd);
          } else {
            if (!visible && !aw.browser.Open(aw.hwnd, configDir))
              return "{\"id\":" + std::to_string(msg.id) +
                     ",\"error\":\"No se pudo abrir el navegador\"}";
            if (attach && !browserDispatch->Attach(aw.hwnd, order, orderPath)) {
              if (!visible)
                aw.browser.Hide();
              return beats::browser_bridge::Fail(msg.id, "host_unavailable");
            }
          }
          return "{\"id\":" + std::to_string(msg.id) +
                 ",\"status\":\"ok\",\"payload\":{}}";
        });
    // The cabina WebUI paints the browser bar and drives the panel through
    // these; the panel's own page WebViews never receive a Bridge.
    beats::RegisterBrowserBridge(*aw.bridge, aw.browser);
    aw.bridge->RegisterHandler(
        "browser.control",
        [&aw, &browserDispatch](const beats::BridgeMessage &msg) {
          beats::preview::Value v;
          if (!beats::browser_bridge::Object(msg, v, {"action"}) ||
              !beats::preview::Text(v, "action", 6))
            return beats::browser_bridge::Fail(msg.id, "invalid_arguments");
          const auto action = v.object.at("action").string;
          if ((action != "take" && action != "resume") || !aw.browser.Visible())
            return beats::browser_bridge::Fail(msg.id, "session_closed");
          // Pause locally before returning to the page message pump. Resume
          // is applied only after the authoritative motor epoch arrives.
          if (action == "take")
            aw.browser.HumanControl();
          else if (!browserDispatch->Control(aw.hwnd, action))
            return beats::browser_bridge::Fail(msg.id, "session_closed");
          return beats::browser_bridge::Ok(msg.id);
        });
    aw.bridge->RegisterHandler(
        "window.open",
        [&supervisor, hInstance, &configDir](const beats::BridgeMessage &msg) {
          beats::OpenWindowRequest r = beats::ParseOpenWindow(msg.payloadJson);
          if (!r.valid) {
            return "{\"id\":" + std::to_string(msg.id) + ",\"error\":\"" +
                   beats::JsonEscapePublic(r.error) + "\"}";
          }
          // La query ?ventana=<id>&vista=..&path=..&order=.. la compone el
          // propio supervisor una vez asignado el id, antes de Initialize.
          std::wstring q =
              L"DevAgents — " + std::wstring(r.vista.begin(), r.vista.end());
          beats::AppWindow *nw =
              supervisor.Create(hInstance, q, 1100, 700, &r, configDir);
          if (!nw)
            return "{\"id\":" + std::to_string(msg.id) +
                   ",\"error\":\"No se pudo crear la ventana\"}";
          nw->window.Show(SW_SHOWNORMAL);
          return "{\"id\":" + std::to_string(msg.id) +
                 ",\"status\":\"ok\",\"payload\":{\"window_id\":" +
                 std::to_string(nw->id) + "}}";
        });
    aw.bridge->RegisterHandler(
        "window.close", [&supervisor](const beats::BridgeMessage &msg) {
          long wid = 0;
          {
            const std::string &p = msg.payloadJson;
            size_t pos = p.find("\"window_id\"");
            if (pos == std::string::npos)
              pos = p.find("\"id_window\"");
            if (pos != std::string::npos) {
              pos = p.find(':', pos);
              if (pos != std::string::npos)
                wid = strtol(p.c_str() + pos + 1, nullptr, 10);
            }
          }
          for (auto &cand : supervisor.All()) {
            if (cand->id == wid && !cand->primary) {
              DestroyWindow(cand->hwnd);
              return "{\"id\":" + std::to_string(msg.id) +
                     ",\"status\":\"ok\",\"payload\":{\"closed\":true}}";
            }
          }
          if (wid <= 0)
            return "{\"id\":" + std::to_string(msg.id) +
                   ",\"error\":\"window_id requerido\"}";
          return "{\"id\":" + std::to_string(msg.id) +
                 ",\"error\":\"ventana no encontrada o es la principal\"}";
        });
    aw.bridge->RegisterHandler(
        "window.list", [&supervisor](const beats::BridgeMessage &msg) {
          std::string arr = "[";
          bool first = true;
          HWND focused = GetForegroundWindow();
          for (const auto &cand : supervisor.All()) {
            if (!first)
              arr += ",";
            first = false;
            arr += "{\"id\":" + std::to_string(cand->id) +
                   ",\"primary\":" + (cand->primary ? "true" : "false") +
                   ",\"vista\":\"" + cand->vista + "\",\"focused\":" +
                   (cand->hwnd == focused ? "true" : "false") + "}";
          }
          arr += "]";
          return "{\"id\":" + std::to_string(msg.id) +
                 ",\"status\":\"ok\",\"payload\":{\"windows\":" + arr + "}}";
        });

    // Selector de carpeta nativo — el modal es propiedad de ESTA ventana.
    const auto pickFolderHandler = [hwnd, &docMgr, &coreClient](
                                       const beats::BridgeMessage &msg) {
      const std::string idStr = std::to_string(msg.id);
      const bool workspaceSelection = msg.kind == "dialog.pickWorkspace";
      // Un selector para lectura no concede escritura. El consentimiento
      // de workspace lleva título del host, no uno elegido por el JS.
      std::string title = workspaceSelection
                              ? "Elige la carpeta de trabajo del agente"
                              : beats::GetStringProp(msg.payloadJson, "title");
      IFileOpenDialog *dlg = nullptr;
      HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                    CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dlg));
      if (FAILED(hr) || !dlg) {
        return "{\"id\":" + idStr +
               ",\"error\":\"No se pudo abrir el dialogo del sistema\"}";
      }
      DWORD opts = 0;
      if (SUCCEEDED(dlg->GetOptions(&opts)))
        dlg->SetOptions(opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM |
                        FOS_PATHMUSTEXIST);
      if (!title.empty()) {
        int wlen = MultiByteToWideChar(CP_UTF8, 0, title.c_str(),
                                       (int)title.size(), nullptr, 0);
        if (wlen > 0) {
          std::wstring wtitle(wlen, 0);
          MultiByteToWideChar(CP_UTF8, 0, title.c_str(), (int)title.size(),
                              &wtitle[0], wlen);
          dlg->SetTitle(wtitle.c_str());
        }
      }
      hr = dlg->Show(hwnd);
      if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
        dlg->Release();
        return "{\"id\":" + idStr +
               ",\"status\":\"ok\",\"payload\":{\"cancelled\":true}}";
      }
      if (FAILED(hr)) {
        dlg->Release();
        return "{\"id\":" + idStr + ",\"error\":\"El dialogo fallo\"}";
      }
      IShellItem *item = nullptr;
      std::string picked;
      std::string authorizationError;
      if (SUCCEEDED(dlg->GetResult(&item)) && item) {
        PWSTR wpath = nullptr;
        if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &wpath)) &&
            wpath) {
          const bool authorized =
              workspaceSelection
                  ? docMgr.AuthorizeWorkspaceRoot(
                        wpath, authorizationError,
                        [&coreClient](const std::wstring &root,
                                      std::string &error) {
                          return coreClient.SetWorkspaceRoot(root, error);
                        })
                  : docMgr.AuthorizeReadRoot(wpath, authorizationError);
          int len = WideCharToMultiByte(CP_UTF8, 0, wpath, -1, nullptr, 0,
                                        nullptr, nullptr);
          if (authorized && workspaceSelection)
            SaveLastWorkspace(coreClient.DataDirectory(), wpath);
          if (authorized && len > 1) {
            picked.resize(len);
            WideCharToMultiByte(CP_UTF8, 0, wpath, -1, &picked[0], len, nullptr,
                                nullptr);
            picked.resize(len - 1);
          }
          CoTaskMemFree(wpath);
        }
        item->Release();
      }
      dlg->Release();
      if (!authorizationError.empty())
        return "{\"id\":" + idStr + ",\"error\":\"" +
               beats::JsonEscapePublic(authorizationError) + "\"}";
      if (picked.empty()) {
        return "{\"id\":" + idStr +
               ",\"error\":\"No se pudo leer la ruta elegida\"}";
      }
      return "{\"id\":" + idStr +
             ",\"status\":\"ok\",\"payload\":{\"cancelled\":false,"
             "\"path\":\"" +
             beats::JsonEscapePublic(picked) + "\"}}";
    };
    aw.bridge->RegisterHandler("dialog.pickFolder", pickFolderHandler);
    aw.bridge->RegisterHandler("dialog.pickWorkspace", pickFolderHandler);

    // Entrada del puente de esta ventana: lo "core."/"search." va a las colas
    // compartidas (con su HWND de origen), el resto se atiende aqui — hilo de
    // UI, bridge propio de la ventana.
    aw.webview.SetMessageCallback([&supervisor, &toWide, &queueMutex, &queueCv,
                                   &requestQueue, &slowCv, &slowQueue, &esLenta,
                                   &discoveryCv, &discoveryQueue, &consentCv,
                                   &consentQueue, &esDescubrimiento,
                                   &checkpointCv, &checkpointQueue,
                                   &aw](const std::wstring &wmsg) {
      if (!beats::WebViewHost::MessageWithinBound(wmsg.size())) {
        OutputDebugStringA("[Bridge] inbound wide message exceeds 28 MiB\n");
        return;
      }
      int size_needed = WideCharToMultiByte(
          CP_UTF8, WC_ERR_INVALID_CHARS, wmsg.data(),
          static_cast<int>(wmsg.size()), NULL, 0, NULL, NULL);
      if (size_needed <= 0 || !beats::WebViewHost::MessageWithinBound(
                                  static_cast<size_t>(size_needed))) {
        OutputDebugStringA("[Bridge] invalid UTF8 or inbound message exceeds "
                           "28 MiB before queue\n");
        return;
      }
      std::string rawJson(static_cast<size_t>(size_needed), 0);
      if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wmsg.data(),
                               static_cast<int>(wmsg.size()), rawJson.data(),
                               size_needed, nullptr, nullptr)) {
        OutputDebugStringA("[Bridge] inbound UTF8 conversion failed\n");
        return;
      }
      const std::string msgKind = beats::Bridge::ExtractKind(rawJson);
      // No hay despacho previo por tipo: todo kind llega a
      // Bridge::HandleMessage (inventario en docs/WEBVIEW-SEGURIDAD.md). Aquí
      // sólo se elige la cola.
      const bool toWorker =
          msgKind.rfind("core.", 0) == 0 || msgKind.rfind("search.", 0) == 0;
      if (toWorker) {
        const bool consentir = beats::RequiresNativeConsent(msgKind);
        const bool descubrir = !consentir && esDescubrimiento(msgKind);
        const bool lenta = !consentir && !descubrir && esLenta(msgKind);
        {
          std::lock_guard<std::mutex> lock(queueMutex);
          if (consentir)
            consentQueue.push_back({rawJson, aw.hwnd, nullptr, aw.bridge});
          else if (descubrir)
            discoveryQueue.push_back({rawJson, aw.hwnd, nullptr, aw.bridge});
          else if (lenta)
            slowQueue.push_back({rawJson, aw.hwnd, nullptr, aw.bridge});
          else
            requestQueue.push_back({rawJson, aw.hwnd, nullptr, aw.bridge});
        }
        if (consentir)
          consentCv.notify_one();
        else if (descubrir)
          discoveryCv.notify_one();
        else if (lenta)
          slowCv.notify_one();
        else
          queueCv.notify_one();
        return;
      }
      if (beats::IsCheckpointKind(msgKind)) {
        {
          std::lock_guard<std::mutex> lock(queueMutex);
          checkpointQueue.push_back({rawJson, aw.hwnd, nullptr, aw.bridge});
        }
        checkpointCv.notify_one();
        return;
      }
      if (!aw.bridge)
        return;
      PostOrReportFailure(aw.webview,
                          toWide(aw.bridge->HandleMessage(rawJson)));
    });

    return aw.webview.Initialize(hwnd, customUserDataDir, bundleDir, devTools,
                                 cmdArgsW);
  });

  // P1-5 (R2 C3): sin el runtime de WebView2 la ventana no puede crearse. Se
  // dice en un diálogo nativo (qué falta, cómo instalarlo y, si viaja con
  // DevAgents, dónde está su instalador) y se sale con un código propio.
  {
    LPWSTR runtimeVersion = nullptr;
    const HRESULT probe =
        GetAvailableCoreWebView2BrowserVersionString(nullptr, &runtimeVersion);
    const bool runtimePresent = SUCCEEDED(probe) && runtimeVersion != nullptr;
    if (runtimeVersion)
      CoTaskMemFree(runtimeVersion);
    if (!runtimePresent) {
      std::wstring setup = ExecutableDirectory();
      if (!setup.empty())
        setup += std::wstring(L"\\") + beats::webview2_missing::SetupFileName();
      const DWORD attrs = setup.empty() ? INVALID_FILE_ATTRIBUTES
                                        : GetFileAttributesW(setup.c_str());
      if (attrs == INVALID_FILE_ATTRIBUTES ||
          (attrs & FILE_ATTRIBUTE_DIRECTORY))
        setup.clear();
      std::cerr << "[DevAgents] WebView2 Runtime no disponible (hr=0x"
                << std::hex << static_cast<unsigned long>(probe) << std::dec
                << "); salida " << beats::webview2_missing::kExitCode
                << std::endl;
      MessageBoxW(nullptr, beats::webview2_missing::Message(setup).c_str(),
                  beats::webview2_missing::Title(), MB_OK | MB_ICONERROR);
      return beats::webview2_missing::kExitCode;
    }
  }

  // La principal se crea por el mismo camino que las secundarias.
  beats::AppWindow *mainAw =
      supervisor.Create(hInstance, L"DevAgents", 1280, 800, nullptr, configDir);
  if (!mainAw)
    return 1;
  HWND mainHwnd = mainAw->hwnd;

  beats::WindowGeometry geo;
  int showCmd = SW_SHOWNORMAL;
  if (mainAw->window.LoadGeometry(configPath, geo)) {
    // La posicion guardada tiene que seguir estando EN UNA PANTALLA.
    //
    // Si se cerro la aplicacion en un segundo monitor y luego se desconecta,
    // esas coordenadas caen fuera del escritorio y la ventana se restaura donde
    // nadie puede verla: parece que no arranco. MonitorFromRect con
    // MONITOR_DEFAULTTONULL devuelve null justo en ese caso, y entonces se deja
    // que Windows la coloque.
    RECT saved = {geo.x, geo.y, geo.x + geo.width, geo.y + geo.height};
    HMONITOR savedMon = MonitorFromRect(&saved, MONITOR_DEFAULTTONULL);
    if (savedMon != nullptr) {
      // El rectangulo guardado no puede exceder el area de trabajo: una
      // ventana normal estirada a mano hasta cubrir la pantalla se restaura
      // sobre la barra de tareas — parece maximizada, pero el borde inferior
      // (la barra de estado) queda enterrado bajo ella. Se recorta al rcWork
      // del monitor donde cae; el maximizado real ya lo limita
      // WM_GETMINMAXINFO y no pasa por aqui.
      MONITORINFO monInfo = {sizeof(monInfo)};
      if (GetMonitorInfoW(savedMon, &monInfo)) {
        const RECT &work = monInfo.rcWork;
        const int workW = static_cast<int>(work.right - work.left);
        const int workH = static_cast<int>(work.bottom - work.top);
        if (geo.width > workW)
          geo.width = workW;
        if (geo.height > workH)
          geo.height = workH;
        if (geo.x < work.left)
          geo.x = static_cast<int>(work.left);
        if (geo.y < work.top)
          geo.y = static_cast<int>(work.top);
        if (geo.x + geo.width > work.right)
          geo.x = static_cast<int>(work.right) - geo.width;
        if (geo.y + geo.height > work.bottom)
          geo.y = static_cast<int>(work.bottom) - geo.height;
      }
      SetWindowPos(mainHwnd, nullptr, geo.x, geo.y, geo.width, geo.height,
                   SWP_NOZORDER | SWP_NOACTIVATE);
    }
    if (geo.maximized) {
      showCmd = SW_SHOWMAXIMIZED;
    }
  }

  // OJO: aqui habia un SW_SHOWNORMAL CABLEADO, que pisaba el
  // SW_SHOWMAXIMIZED que se acababa de decidir tres lineas mas arriba. Una
  // ventana cerrada en maximizado se restauraba siempre en tamano normal, y el
  // codigo que lo calculaba no servia para nada.
  mainAw->window.Show(showCmd);
  SetForegroundWindow(mainHwnd);

  // E5.21: reabrir las secundarias que quedaron abiertas la ultima vez, con
  // su vista y parametros (path/order) — el supervisor recompone la query con
  // el id nuevo.
  for (const auto &r : supervisor.LoadSecondaryViews(configDir)) {
    beats::OpenWindowRequest req = r;
    std::wstring q =
        L"DevAgents — " + std::wstring(r.vista.begin(), r.vista.end());
    // La geometria guardada en windows.ini restaura posicion y tamano; sin
    // ella las ventanas reaparecian apiladas a 1100x700 en la esquina.
    const int rw = req.w > 0 ? req.w : 1100;
    const int rh = req.h > 0 ? req.h : 700;
    if (beats::AppWindow *nw =
            supervisor.Create(hInstance, q, rw, rh, &req, configDir)) {
      if (req.x != 0 || req.y != 0)
        SetWindowPos(nw->hwnd, nullptr, req.x, req.y, 0, 0,
                     SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
      nw->window.Show(req.maximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL);
    }
  }

  // Instanciar servicios nativos del host C++.
  //
  // NO se lanza devagents-core.exe --supervised: ese modo es un bucle vacio
  // (`while (true) Sleep(1000)` en core/src/cli.zig) que no atiende a nadie.
  // El motor real se carga en este mismo proceso a traves de
  // devagents_core.dll, asi que un subproceso ocioso solo servia para poder
  // ensenar un PID en la barra de estado.

  // ---------------------------------------------------------------------
  // Hilos de trabajo del motor.
  //
  // El puente atendia TODO en el hilo de UI. Cualquier peticion que hiciera
  // red o disco pesado —sondear la salud de los modelos, descubrir modelos,
  // buscar en el proyecto, hablar con un servidor MCP— congelaba la ventana
  // mientras durase, y una espera larga acaba con Windows marcando la app
  // como "no responde" (que es lo que veia el usuario al pulsar
  // "Sondear ahora").
  //
  // Las peticiones al motor pasan por colas que consumen hilos dedicados.
  //
  // H4b — y son DOS colas, no una. Con una sola, cualquier peticion rapida se
  // ponia detras de la lenta que estuviera en curso. Medido el 2026-08-06 y
  // escrito en `live_worker.callWithDeadline`: un `core.complete` tardo
  // 96.375 ms y el `core.status()` siguiente espero 96.382 ms — no porque
  // costara nada, sino porque el que iba delante no habia vuelto. La ventana
  // no se congelaba (eso lo arreglo H4), pero el arbol de archivos, las
  // pestanas y la busqueda se quedaban mudos durante minutos.
  //
  // El corte es por lo unico que importa aqui: si la peticion sale a la RED.
  // Las que hablan con un proveedor o con un servidor MCP tardan segundos o
  // minutos; las demas son disco y SQLite, y vuelven en milisegundos. Cada
  // grupo tiene su hilo, y ninguno espera al otro.
  //
  // Es seguro que sean dos: SQLite se compila con SQLITE_THREADSAFE=1 (modo
  // serializado, ver `build.zig`), asi que una misma conexion admite varios
  // hilos, y el estado del C API ya esta protegido por sus propios mutex.
  //
  // E5.21: cada peticion en cola lleva el HWND de la ventana que la pidio. El
  // worker la ejecuta con el bridge DE ESA ventana y la respuesta vuelve a
  // ESA ventana mediante la cola UI e identidad del puente.
  // ---------------------------------------------------------------------
  std::thread engineWorker([&]() {
    for (;;) {
      QueuedRequest request;
      {
        std::unique_lock<std::mutex> lock(queueMutex);
        queueCv.wait(lock, [&] { return workerStop || !requestQueue.empty(); });
        if (workerStop && requestQueue.empty())
          return;
        request = std::move(requestQueue.front());
        requestQueue.pop_front();
      }
      if (request.task) {
        request.task();
        continue;
      }
      trace("IN ", request.json);
      // Si cerro o se reemplazo mientras esperaba, no ejecutar su peticion.
      // El puente retenido mantiene segura una ejecucion que ya comenzo.
      auto bridge = request.bridge;
      if (!bridge || supervisor.BridgeForHwnd(request.src) != bridge) {
        trace("OUT", request.json);
        continue;
      }
      std::string response = bridge->HandleMessage(request.json);
      trace("OUT", request.json);
      // El WebView es STA: solo el hilo de UI puede publicarle mensajes, asi
      // que la respuesta va a la cola UI con su HWND e identidad original.
      // La cola de hilo no pierde el payload cuando se destruye ese HWND.
      auto *payload = new EngineResponse{request.src, bridge, toWide(response)};
      if (!PostThreadMessageW(uiThreadId, WM_BEATS_ENGINE_RESPONSE, 0,
                              reinterpret_cast<LPARAM>(payload))) {
        delete payload;
      }
      // E5.21 — difusion de estado: una mutacion en una ventana (orden,
      // sesion, gobernanza/presupuesto) puede cambiar lo que muestran las
      // demas. Push engine.changed a TODAS; la WebUI decide si revalida.
      const std::string k = beats::Bridge::ExtractKind(request.json);
      if (k.rfind("core.order.", 0) == 0 || k.rfind("core.session", 0) == 0 ||
          k == "core.governance.set" || k == "core.budget.set" ||
          k == "core.theme.set") {
        broadcastFromAnyThread("{\"push\":\"engine.changed\",\"payload\":{"
                               "\"kind\":\"" +
                               k + "\"}}");
      }
    }
  });

  // H4b: carril lento. Mismo cuerpo, otra cola: lo que sale a la red no
  // puede tapar al resto. El carril de descubrimiento usa el mismo cuerpo.
  auto runLane = [&](std::deque<QueuedRequest> &queue,
                     std::condition_variable &cv, const char *inTag,
                     const char *outTag) {
    for (;;) {
      QueuedRequest request;
      {
        std::unique_lock<std::mutex> lock(queueMutex);
        cv.wait(lock, [&] { return workerStop || !queue.empty(); });
        if (workerStop && queue.empty())
          return;
        request = std::move(queue.front());
        queue.pop_front();
      }
      trace(inTag, request.json);
      auto bridge = request.bridge;
      if (!bridge || supervisor.BridgeForHwnd(request.src) != bridge) {
        trace(outTag, request.json);
        continue;
      }
      std::string response = bridge->HandleMessage(request.json);
      trace(outTag, request.json);
      auto *payload = new EngineResponse{request.src, bridge, toWide(response)};
      if (!PostThreadMessageW(uiThreadId, WM_BEATS_ENGINE_RESPONSE, 0,
                              reinterpret_cast<LPARAM>(payload))) {
        delete payload;
      }
      // Tanda 5: una comprobación, una descarga o un ajuste del actualizador
      // cambia lo que enseñan TODAS las ventanas (aviso y Ajustes). El estado
      // (core.update.state) no lo cambia y no difunde: si no, cada ventana
      // que lo vuelve a pedir provocaría otra difusión.
      const std::string updateKind = beats::Bridge::ExtractKind(request.json);
      if (updateKind.rfind("core.update.", 0) == 0 &&
          updateKind != "core.update.state")
        broadcastFromAnyThread("{\"push\":\"update.changed\",\"payload\":{}}");
    }
  };
  std::thread engineSlowWorker(
      [&]() { runLane(slowQueue, slowCv, "IN-S", "OUT-S"); });
  std::thread engineDiscoveryWorker(
      [&]() { runLane(discoveryQueue, discoveryCv, "IN-D", "OUT-D"); });
  std::thread engineConsentWorker(
      [&]() { runLane(consentQueue, consentCv, "IN-C", "OUT-C"); });
  std::thread checkpointWorker([&]() {
    // Indices de puntos de control que dejaron hosts cerrados sin limpiar
    // (mas de 7 dias); nunca los de esta sesion ni los de un host vivo.
    beats::PruneStaleCheckpointIndexes(beats::CheckpointIndexDir(),
                                       7ULL * 24 * 60 * 60 * 1000,
                                       GetCurrentProcessId());
    runLane(checkpointQueue, checkpointCv, "IN-K", "OUT-K");
  });

  NOTIFYICONDATAW tray = {};
  tray.cbSize = sizeof(tray);
  tray.hWnd = mainHwnd;
  tray.uID = 1;
  tray.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray.uCallbackMessage = beats::notifications::Callback;
  tray.hIcon = reinterpret_cast<HICON>(
      SendMessageW(mainHwnd, WM_GETICON, ICON_SMALL, 0));
  if (!tray.hIcon)
    tray.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
  wcscpy_s(tray.szTip, L"DevAgents — órdenes");
  bool trayReady = Shell_NotifyIconW(NIM_ADD, &tray) != FALSE;
  if (!trayReady)
    std::cerr << "DevAgents: no se pudo añadir el icono de bandeja\n";
  std::atomic<bool> notificationStop{false};
  HANDLE notificationStopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!notificationStopEvent)
    std::cerr << "DevAgents: no se pudo preparar cancelación de avisos\n";
  std::thread notificationWorker([&] {
    long long cursor = -1;
    while (!notificationStop.load()) {
      if (notificationStopEvent) {
        const auto result = beats::DispatchCoreCall(
            enqueueCoreTask,
            [&, cursor] {
              if (!coreClient.EngineReady() ||
                  !coreClient.Api().notifications_since_json)
                return beats::CoreResult{-1, "",
                                         "Motor de avisos no disponible"};
              char *raw = nullptr;
              const int rc = coreClient.Api().notifications_since_json(
                  coreClient.Handle(), cursor, &raw);
              return beats::CoreResult{rc, coreClient.TakeString(raw), ""};
            },
            notificationStopEvent);
        beats::preview::Value value;
        if (result.ok() &&
            beats::preview::Parser(result.json, true).Parse(value) &&
            beats::preview::Number(value, "cursor", 0, 9007199254740991.0) &&
            value.object.count("items") &&
            value.object.at("items").type == beats::preview::Value::Array) {
          cursor = static_cast<long long>(value.object.at("cursor").number);
          for (const auto &item : value.object.at("items").array) {
            if (!beats::preview::Number(item, "order_id", 1,
                                        9007199254740991.0) ||
                !beats::preview::Text(item, "state", 64))
              continue;
            const long long order =
                static_cast<long long>(item.object.at("order_id").number);
            const std::string state = item.object.at("state").string;
            if (beats::notifications::Title(state).empty())
              continue;
            {
              std::lock_guard<std::mutex> guard(notificationMutex);
              notifications.emplace_back(order, state);
            }
            if (!PostThreadMessageW(uiThreadId, WM_BEATS_NOTIFICATION, 0, 0))
              std::cerr << "DevAgents: no se pudo encolar aviso nativo\n";
          }
        } else
          std::cerr << "DevAgents: consulta de avisos fallida\n";
      }
      for (int tick = 0; tick < 20 && !notificationStop.load(); ++tick)
        Sleep(100);
    }
  });
  std::deque<std::pair<long long, std::string>> balloonQueue;
  bool balloonActive = false;
  auto showNextBalloon = [&] {
    if (balloonActive)
      return;
    while (!balloonQueue.empty()) {
      const auto item = std::move(balloonQueue.front());
      balloonQueue.pop_front();
      const HWND foreground = GetAncestor(GetForegroundWindow(), GA_ROOT);
      balloonFocused = supervisor.ByHwnd(foreground) != nullptr;
      observedOrder = item.first;
      balloonState = item.second;
      balloonSent = false;
      if (trayReady &&
          beats::notifications::ShouldNotify(balloonState, balloonFocused)) {
        auto info = beats::notifications::Balloon(mainHwnd, observedOrder,
                                                  balloonState);
        balloonSent = Shell_NotifyIconW(NIM_MODIFY, &info) != FALSE;
        if (balloonSent) {
          balloonOrder = observedOrder;
          balloonActive = true;
          return;
        }
        std::cerr << "DevAgents: aviso de bandeja fallido\n";
      }
    }
  };
  // Remate D7: respuestas y difusiones del motor también se entregan dentro
  // del bucle de un diálogo modal (autorización nativa): antes se perdían.
  auto deliverEngineMessage = [&](const MSG &m) -> bool {
    if (m.message == WM_BEATS_ENGINE_RESPONSE) {
      std::unique_ptr<EngineResponse> payload(
          reinterpret_cast<EngineResponse *>(m.lParam));
      if (payload) {
        if (auto *aw = supervisor.ByHwnd(payload->src, payload->bridge))
          PostOrReportFailure(aw->webview, payload->json);
      }
      return true;
    }
    if (m.message == WM_BEATS_ENGINE_PUSH) {
      // Evento de difusion (doc.saved, fs.changed, ...): llega a la cola de
      // UI desde cualquier hilo y se repite en TODAS las ventanas vivas.
      std::unique_ptr<std::wstring> payload(
          reinterpret_cast<std::wstring *>(m.lParam));
      if (payload)
        supervisor.Broadcast(*payload);
      return true;
    }
    return false;
  };
  beats::themed::ThreadMessages() = deliverEngineMessage;
  MSG msg = {};
  while (GetMessage(&msg, nullptr, 0, 0)) {
    // WM_DESTROY ya retorno: Window y los callbacks se pueden liberar.
    // Los workers conservan un shared_ptr al puente si seguian trabajando.
    supervisor.CollectDestroyedWindows();
    if (!IsWindow(mainHwnd) && !supervisor.All().empty()) {
      // La bandeja tambien necesita un propietario vivo para sus clics.
      if (trayReady)
        Shell_NotifyIconW(NIM_DELETE, &tray);
      mainHwnd = supervisor.All().front()->hwnd;
      tray.hWnd = mainHwnd;
      trayReady = Shell_NotifyIconW(NIM_ADD, &tray) != FALSE;
      if (!trayReady)
        std::cerr << "DevAgents: no se pudo trasladar el icono de bandeja\n";
      if (balloonActive && balloonOrder > 0)
        balloonQueue.emplace_front(balloonOrder, balloonState);
      balloonActive = false;
      showNextBalloon();
    }
    if (msg.message == beats::BrowserDispatch::Message) {
      auto *aw = supervisor.ByHwnd(msg.hwnd);
      browserDispatch->Deliver(
          msg.lParam, aw ? &aw->browser : nullptr,
          [&supervisor, hwnd = msg.hwnd](const std::string &event) {
            if (auto *target = supervisor.ByHwnd(hwnd))
              target->webview.PostMessageJson(beats::preview::Wide(event));
          });
      continue;
    }
    if (msg.message == WM_BEATS_NOTIFICATION) {
      std::deque<std::pair<long long, std::string>> pending;
      {
        std::lock_guard<std::mutex> guard(notificationMutex);
        pending.swap(notifications);
      }
      for (auto &item : pending)
        balloonQueue.push_back(std::move(item));
      showNextBalloon();
      continue;
    } else if (msg.message == beats::notifications::Callback) {
      if ((msg.lParam == NIN_BALLOONUSERCLICK || msg.lParam == WM_LBUTTONUP) &&
          balloonOrder > 0) {
        beats::OpenWindowRequest request;
        request.valid = true;
        request.vista = "conversacion";
        request.orderId = static_cast<long>(balloonOrder);
        beats::AppWindow *opened = supervisor.Create(
            hInstance, L"DevAgents — orden", 1100, 700, &request, configDir);
        if (opened) {
          opened->window.Show(SW_SHOWNORMAL);
          SetForegroundWindow(opened->hwnd);
        } else
          std::cerr << "DevAgents: no se pudo abrir la orden del aviso\n";
      }
      if (msg.lParam == NIN_BALLOONUSERCLICK ||
          msg.lParam == NIN_BALLOONTIMEOUT || msg.lParam == NIN_BALLOONHIDE) {
        balloonActive = false;
        showNextBalloon();
      }
      continue;
    } else if (msg.message == WM_APP + 42) {
      if (beats::AppWindow *aw = supervisor.ByHwnd(msg.hwnd))
        aw->webview.DumpDomToCdpFile();
      continue;
    } else if (msg.message == WM_BEATS_ENGINE_RESPONSE ||
               msg.message == WM_BEATS_ENGINE_PUSH) {
      deliverEngineMessage(msg);
      continue;
    }
    supervisor.DispatchWindowMessage(msg);
  }
  // Fuera del bucle principal ya no hay a quién entregar desde un diálogo.
  beats::themed::ThreadMessages() = nullptr;

  notificationStop = true;
  if (notificationStopEvent)
    SetEvent(notificationStopEvent);
  if (notificationWorker.joinable())
    notificationWorker.join();
  if (notificationStopEvent)
    CloseHandle(notificationStopEvent);
  if (trayReady && !Shell_NotifyIconW(NIM_DELETE, &tray))
    OutputDebugStringW(L"DevAgents: no se pudo retirar el icono de bandeja\n");
  remote.Stop();
  browserDispatch->Stop();
  // Un worker puede estar esperando una autorización nativa que ya no se
  // mostrará: se le responde «no» antes de unirlo.
  beats::consent::Shutdown();
  {
    std::lock_guard<std::mutex> lock(queueMutex);
    workerStop = true;
  }
  queueCv.notify_all();
  slowCv.notify_all();
  discoveryCv.notify_all();
  consentCv.notify_all();
  checkpointCv.notify_all();
  if (engineWorker.joinable()) {
    engineWorker.join();
  }
  // H4b: el carril lento se cierra igual. Puede tardar mas en volver —esta
  // esperando a la red—, pero se le espera: dejarlo suelto seria abandonar un
  // hilo que todavia habla con el motor mientras el proceso se apaga.
  if (engineSlowWorker.joinable()) {
    engineSlowWorker.join();
  }
  if (engineDiscoveryWorker.joinable()) {
    engineDiscoveryWorker.join();
  }
  if (engineConsentWorker.joinable()) {
    engineConsentWorker.join();
  }
  if (checkpointWorker.joinable()) {
    checkpointWorker.join();
  }

  // Los workers ya no publican; liberar respuestas a ventanas que cerraron
  // antes de que la UI consumiera la cola (tambien su referencia al puente).
  MSG pendingResponse{};
  while (PeekMessageW(&pendingResponse, nullptr, WM_BEATS_ENGINE_RESPONSE,
                      WM_BEATS_ENGINE_RESPONSE, PM_REMOVE)) {
    delete reinterpret_cast<EngineResponse *>(pendingResponse.lParam);
  }
  // Tanda 5 (F0.4): ¿hay una actualización aceptada que aplicar? Se le
  // pregunta al motor ANTES de pararlo (los workers ya terminaron: ninguna
  // petición nueva puede lanzar una orden). El motor solo da la ruta si no
  // queda ninguna orden en curso y la huella del instalador no cambió.
  std::wstring pendingInstaller;
  std::string pendingSha256;
  if (coreClient.EngineReady() && coreClient.Api().update_pending_apply_json) {
    const beats::CoreResult pending =
        coreClient.CallJson(coreClient.Api().update_pending_apply_json);
    const auto parsed = beats::update::ParsePendingApply(pending.json);
    if (!pending.ok())
      beats::update::AppendLog(coreClient.DataDirectory(),
                               "al cerrar: no se pudo preguntar al motor: " +
                                   pending.error);
    else if (!parsed.valid)
      beats::update::AppendLog(coreClient.DataDirectory(),
                               "al cerrar: respuesta del motor ilegible");
    else if (parsed.apply) {
      pendingInstaller = parsed.path;
      pendingSha256 = parsed.sha256;
    } else if (parsed.reason != "no hay ninguna actualización preparada")
      beats::update::AppendLog(coreClient.DataDirectory(),
                               "al cerrar: no se aplica: " + parsed.reason);
  }
  coreClient.StopCoreProcess();
  if (!pendingInstaller.empty()) {
    // Con el motor parado: si no queda ningún otro devagents-*.exe de la
    // carpeta de instalación, se lanza el instalador y el host termina normal.
    wchar_t hostExe[MAX_PATH];
    const DWORD n = GetModuleFileNameW(nullptr, hostExe, MAX_PATH);
    std::wstring installDir = n ? std::wstring(hostExe, n) : std::wstring();
    const size_t slash = installDir.find_last_of(L"\\/");
    installDir = slash == std::wstring::npos ? std::wstring()
                                             : installDir.substr(0, slash);
    const std::wstring dataDir = coreClient.DataDirectory();
    beats::update::AppendLog(
        dataDir,
        "al cerrar: " +
            (installDir.empty()
                 ? std::string("no se aplica: no se pudo leer la carpeta de "
                               "instalación")
                 : beats::update::ApplyOnExit(
                       pendingInstaller, installDir,
                       dataDir.empty() ? std::wstring()
                                       : dataDir + L"\\update-install.log",
                       dataDir, pendingSha256)));
  }
  // windows.ini y la geometria principal se guardaron en WM_DESTROY.
  // Todos los workers han terminado: se pueden liberar los ultimos objetos.
  supervisor.CollectDestroyedWindows();
  OleUninitialize();
  return static_cast<int>(msg.wParam);
}

int main(int argc, char **argv) {
  std::string cmdLine;
  for (int i = 1; i < argc; ++i) {
    if (i > 1)
      cmdLine += " ";
    cmdLine += argv[i];
  }
  return WinMain(GetModuleHandle(NULL), NULL, (LPSTR)cmdLine.c_str(), SW_SHOW);
}
