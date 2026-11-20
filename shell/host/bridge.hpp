#ifndef BEATS_BRIDGE_HPP
#define BEATS_BRIDGE_HPP

#include <functional>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace beats {

class DocumentManager;
class FileWatcher;
class ProjectSearch;
class HunkManager;
class PtyManager;
class LspClient;
class CoreClient;

struct BridgeMessage {
  int id = 0;
  std::string kind;
  std::string payloadJson;
};

// Utilidades del puente, publicas porque main.cpp registra handlers propios
// (window.command, dialog.pickFolder) que necesitan hablar el mismo JSON.
//
// JsonEscape NO se duplica a proposito. Es la correccion del fallo un
// documento con un caracter de control en crudo hace que
// PostWebMessageAsJson lo rechace en silencio, la promesa del cliente quede
// pendiente para siempre y el panel se congele sin un error a la vista. Una
// segunda copia acabaria divergiendo de esta y reabriendo el fallo por el otro
// lado.
// Rutas git relativas; traversal nunca se oculta como salida interna.
bool IsEngineInternalPath(const std::string &path);
// Remate D5 (10-nov): lanza un programa sin consola y captura stdout/stderr.
// El hijo hereda solo sus tres extremos y la lectura no espera el EOF de una
// copia de la tuberia que otro proceso conserve (ver bridge.cpp). La usan
// RunGitCapture y los comandos WSL; publica para la prueba del host.
std::string RunCapture(const std::string &cwd, const std::wstring &executable,
                       const std::vector<std::wstring> &args, std::string &err,
                       unsigned long timeoutMs);
// B1 (10-nov): igual que RunCapture con variables de entorno sustituidas en el
// hijo (el punto de control lanza git con su propio GIT_INDEX_FILE).
std::string RunCaptureEnv(
    const std::string &cwd, const std::wstring &executable,
    const std::vector<std::wstring> &args,
    const std::vector<std::pair<std::wstring, std::wstring>> &extraEnv,
    std::string &err, unsigned long timeoutMs);
// Remate D7: kinds que PUEDEN pedir autorizacion nativa (dialogo modal) antes
// de ejecutarse. main.cpp los saca del carril rapido para que la espera del
// dialogo no congele el resto de peticiones. (12-nov): que una
// llamada concreta pregunte lo decide Bridge::DecideConsent (endurecer los
// permisos, un modo ya habilitado o un servidor ya aprobado no preguntan).
bool RequiresNativeConsent(const std::string &kind);
// archivo, en la carpeta de datos, con los modos de permisos que
// la persona habilito una vez en el dialogo nativo (una linea por modo). Solo
// lo escribe el host; la pagina no tiene ninguna via para crearlo.
extern const wchar_t kElevatedModesFile[];
// B1e (11-nov): checkpoint.create/restore lanzan git (~0,4 s, mas con un arbol
// grande) y create va en cada envio de Directo. main.cpp los atiende en un
// carril propio, fuera del hilo de la interfaz y en orden entre ellos (el
// mapa de puntos emitidos solo lo toca ese carril).
bool IsCheckpointKind(const std::string &kind);
// Carpeta de los indices de los puntos de control (%TEMP%); vacia si no hay.
std::wstring CheckpointIndexDir();
// Borra los indices de mas de `maxAgeMs` de procesos que ya no viven (nunca
// los de `currentPid`). Devuelve cuantos borro.
size_t PruneStaleCheckpointIndexes(const std::wstring &dir,
                                   unsigned long long maxAgeMs,
                                   unsigned long currentPid);
std::string JsonEscapePublic(const std::string &s);
std::string GetStringProp(const std::string &json, const std::string &key);

class Bridge {
public:
  using MessageHandler = std::function<std::string(const BridgeMessage &msg)>;

  Bridge();
  ~Bridge();

  bool ValidateSchema(const std::string &rawJson, BridgeMessage &outMsg);
  std::string HandleMessage(const std::string &rawJson);

  // `kind` del nivel superior sin validar el mensaje entero. main.cpp lo usa
  // para repartir colas (core.*/search.* y la lista de lentas): leer el tipo
  // por substring aceptaba `"kind"` escritas dentro del payload y no veía las
  // que llevaban espacios (`"kind": "core.x"`).
  static std::string ExtractKind(const std::string &rawJson);

  // core.order.worktree sólo puede conceder escritura sobre la carpeta de una
  // orden creada en esta sesión (core.order.submit / fromIssue, común a todas
  // las ventanas) o que ya cuelga de una raíz concedida por el host. Una orden
  // histórica fuera de esas raíces exige elegirla con dialog.pickWorkspace.
  static void NoteSessionOrder(long long orderId);
  static bool IsSessionOrder(long long orderId);
  static bool AuthorizeOrderWorktree(DocumentManager &documents,
                                     bool sessionOrder, const std::string &path,
                                     std::string &cause);

  void RegisterHandler(const std::string &kind, MessageHandler handler);
  std::vector<std::string> RegisteredHandlerNames() const;
  void BindServices(DocumentManager *docMgr, FileWatcher *fileWatcher,
                    ProjectSearch *projectSearch, HunkManager *hunkMgr,
                    PtyManager *ptyMgr, LspClient *lspClient,
                    CoreClient *coreClient);

  // E5.21: eventos que el host difunde a TODAS las ventanas (documento
  // guardado, fs.changed, tema, sesiones, ordenes). El sink lo fija main.cpp;
  // cada mensaje es un sobre {"push":"<topic>","payload":{...}} sin `id`
  // (el cliente JS lo distingue de las respuestas).
  using EventSink = std::function<void(const std::string &jsonMessage)>;
  void SetEventSink(EventSink sink) { m_eventSink = std::move(sink); }
  void SetDialogOwner(void *hwnd) { m_dialogOwner = hwnd; }

  // Autorización nativa de las capacidades privilegiadas. El diálogo muestra
  // la acción (fijada por el host) y el recurso (indicado por la página, con
  // control/bidi neutralizados, URL sin credenciales y secretos omitidos) y se
  // abre en el hilo de la ventana propietaria (consent_prompt.hpp). El
  // presentador sólo lo inyectan las pruebas del host.
  using ConsentPresenter = std::function<bool(
      void *owner, const std::wstring &title, const std::wstring &body)>;
  void SetConsentPresenter(ConsentPresenter presenter) {
    m_consentPresenter = std::move(presenter);
  }
  static std::wstring
  ConsentText(const std::string &kind, const std::string &payloadJson,
              const std::wstring &closing =
                  L"Si lo permites, vale solo para esta vez.");
  void EmitEvent(const std::string &topic, const std::string &payloadJson);

  // carpeta donde se recuerdan los modos habilitados. Sin fijar,
  // se usa CoreClient::DataDirectory (BEATS_DATA_DIR / DEVAGENTS_DATA_DIR /
  // %LOCALAPPDATA%\DevAgents-Angel). Las pruebas la apuntan a una temporal.
  void SetConsentMemoryDir(std::wstring dir) {
    std::lock_guard<std::mutex> lock(m_consentMutex);
    m_consentMemoryDir = std::move(dir);
  }
  // Lectura de la configuracion de permisos vigente ({"mode","allow","deny"})
  // para comparar con la pedida. Por defecto, da_get_permission_config; las
  // pruebas inyectan otra. Devuelve false (y el motivo) si no se pudo leer.
  using PermissionReader =
      std::function<bool(std::string &json, std::string &error)>;
  void SetPermissionReader(PermissionReader reader) {
    m_permissionReader = std::move(reader);
  }

private:
  std::string CreateErrorResponse(int id, const std::string &errorMsg);

  // Que hace falta antes de ejecutar un kind de RequiresNativeConsent.
  struct ConsentDecision {
    bool ask = false;
    std::wstring body;        // vacio: ConsentText del kind
    std::string error;        // no vacio: se rechaza sin dialogo
    bool rewrite = false;     // el handler recibe `payload` en su lugar
    std::string payload;      // payload canonico (core.permissions.set)
    std::string rememberMode; // modo que se recuerda si sale bien
    std::string sessionGrant; // destino aprobado hasta cerrar el host
  };
  ConsentDecision DecideConsent(const BridgeMessage &msg);
  ConsentDecision DecidePermissionsConsent(const BridgeMessage &msg);
  bool ReadPermissionConfig(std::string &json, std::string &error);
  std::wstring ConsentMemoryDir();
  std::unordered_set<std::string> RememberedModes(std::string &error);
  bool RememberMode(const std::string &mode, std::string &error);
  bool ForgetElevatedModes(std::string &error);

  // Superficie agentica (core.*): proveedores, claves, modelos, ordenes,
  // sesiones, ledger, aprobaciones y MCP contra devagents_core.dll.
  void BindCoreHandlers(CoreClient *coreClient);
  // Listado de directorios (fs.list) para el explorador de archivos.
  void BindFsHandlers(DocumentManager *docMgr);

  std::unordered_map<std::string, MessageHandler> m_handlers;
  EventSink m_eventSink;
  void *m_dialogOwner = nullptr;
  ConsentPresenter m_consentPresenter;
  PermissionReader m_permissionReader;
  CoreClient *m_core = nullptr;
  LspClient *m_lsp = nullptr;
  // Protege la carpeta del recuerdo, su archivo y los destinos aprobados en
  // esta sesion (los workers del host atienden peticiones en paralelo).
  std::mutex m_consentMutex;
  std::wstring m_consentMemoryDir;
  std::unordered_set<std::string> m_sessionGrants;
  DocumentManager *m_documents = nullptr;
  // A bridge/popout can restore only snapshots issued by that host bridge.
  // B1 (10-nov): cada punto de control es un arbol git de TODO lo no ignorado
  // (seguido y sin seguimiento) y conserva su indice propio: con el se sabe
  // que creo la ejecucion (lo que el indice no conoce) y que cambio o borro.
  struct CheckpointRecord {
    std::wstring indexPath;       // indice temporal fuera del proyecto
    std::wstring emptyTree;       // GIT_ATTR_SOURCE: foto sin atributos
    unsigned long long createdAt; // FILETIME de la foto (carpetas nuevas)
    // T1-D2 (12-nov): el indice REAL del repositorio (lo que preparan
    // `git add`/`git mv`) y su copia byte a byte junto a la foto. Sin copia,
    // `realIndexNote` dice por que y restore no toca el indice real.
    std::wstring realIndex;
    std::wstring realIndexCopy;
    std::string realIndexNote;
  };
  std::unordered_map<std::wstring,
                     std::unordered_map<std::string, CheckpointRecord>>
      m_checkpoints;
};

} // namespace beats

#endif // BEATS_BRIDGE_HPP
