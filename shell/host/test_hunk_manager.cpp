// Estas pruebas se apoyan en DA_CHECK(): ningún modo de optimización (NDEBUG)
// las puede compilar fuera. Debe ir antes de cualquier #include.
#include "document_manager.hpp"
#include "hunk_manager.hpp"
#include "test_check.hpp"
#include <cstdio>
#include <fstream>
#include <iostream>
#include <vector>
#include <windows.h>

namespace {

// Crea los ficheros de prueba con la API nativa: el nombre puede ser una ruta
// absoluta y no depende del directorio de trabajo del proceso.
bool WriteFixture(const std::wstring &path, const std::string &text) {
  HANDLE handle = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (handle == INVALID_HANDLE_VALUE)
    return false;
  DWORD written = 0;
  const bool ok =
      WriteFile(handle, text.data(), static_cast<DWORD>(text.size()), &written,
                nullptr) &&
      written == text.size();
  CloseHandle(handle);
  return ok;
}

bool ReadFixture(const std::wstring &path, std::string &text) {
  HANDLE handle =
      CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (handle == INVALID_HANDLE_VALUE)
    return false;
  LARGE_INTEGER size{};
  bool ok = GetFileSizeEx(handle, &size) && size.QuadPart >= 0 &&
            size.QuadPart <= 16 * 1024 * 1024;
  if (ok) {
    text.resize(static_cast<size_t>(size.QuadPart));
    DWORD read = 0;
    ok = text.empty() ||
         (ReadFile(handle, text.data(), static_cast<DWORD>(text.size()), &read,
                   nullptr) &&
          read == text.size());
  }
  CloseHandle(handle);
  return ok;
}

// Directorio temporal propio y único por corrida: evita que corridas paralelas
// (o una comprobación fallida) dejen ficheros de nombre fijo en el directorio
// de trabajo del proceso. El destructor borra todo su contenido.
struct TempWorkspace {
  std::wstring dir;
  std::wstring file1;
  std::wstring file2;
  std::wstring file3;
  std::wstring file4;
  bool created = false;

  bool Create() {
    // Los temporales de la prueba viven dentro del worktree (.tmp-orq), nunca
    // en %TEMP%: la regla de entorno del proyecto prohíbe escribir fuera de él.
    wchar_t cwd[32768];
    const DWORD length = GetCurrentDirectoryW(32768, cwd);
    if (!length || length >= 32768)
      return false;
    const std::wstring root = std::wstring(cwd) + L"\\.tmp-orq";
    CreateDirectoryW(root.c_str(), nullptr);
    LARGE_INTEGER tick{};
    QueryPerformanceCounter(&tick);
    wchar_t name[64];
    swprintf(name, 64, L"beats_hunk_test_%08lx_%08lx%08lx",
             static_cast<unsigned long>(GetCurrentProcessId()),
             static_cast<unsigned long>(tick.HighPart),
             static_cast<unsigned long>(tick.LowPart));
    dir = root + L"\\" + name;
    if (!CreateDirectoryW(dir.c_str(), nullptr))
      return false;
    file1 = dir + L"\\beats_hunk_test_1.txt";
    file2 = dir + L"\\beats_hunk_test_2.txt";
    file3 = dir + L"\\beats_hunk_test_3.txt";
    file4 = dir + L"\\beats_hunk_test_4.txt";
    created = true;
    return true;
  }

  // Borra el directorio temporal completo, incluidos los restos de guardado
  // atómico (`.devagents-save-*.tmp`), para no dejar basura.
  void Cleanup() {
    if (!created)
      return;
    WIN32_FIND_DATAW data{};
    const HANDLE find = FindFirstFileW((dir + L"\\*").c_str(), &data);
    if (find != INVALID_HANDLE_VALUE) {
      do {
        if (wcscmp(data.cFileName, L".") == 0 ||
            wcscmp(data.cFileName, L"..") == 0)
          continue;
        const std::wstring path = dir + L"\\" + data.cFileName;
        if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
          RemoveDirectoryW(path.c_str());
        else
          DeleteFileW(path.c_str());
      } while (FindNextFileW(find, &data));
      FindClose(find);
    }
    RemoveDirectoryW(dir.c_str());
    created = false;
  }

  ~TempWorkspace() { Cleanup(); }
};

bool test_hunk_accept_reject_hash_verification() {
  TempWorkspace ws;
  if (!ws.Create()) {
    std::cout << "[FAIL] No se pudo crear el directorio temporal\n";
    return false;
  }

  const std::string origContent = "Line 1\nLine 2\nLine 3\n";
  if (!WriteFixture(ws.file1, origContent) ||
      !WriteFixture(ws.file2, origContent)) {
    std::cout << "[FAIL] No se pudieron crear los ficheros de la prueba\n";
    return false;
  }

  beats::Hunk hunk1;
  hunk1.id = 1;
  hunk1.originalContent = origContent;
  hunk1.newContent = "Line 1\nLine 2 ACCEPTED\nLine 3\n";

  beats::Hunk hunk2;
  hunk2.id = 2;
  hunk2.originalContent = origContent;
  hunk2.newContent = "Line 1\nLine 2 REJECTED\nLine 3\n";

  std::vector<beats::Hunk> hunks = {hunk1, hunk2};

  bool accepted = false;
  bool rejected = false;
  std::string outContent1;
  std::string outContent2;
  {
    // El DocumentManager retiene handles de la raíz autorizada (sin
    // FILE_SHARE_DELETE), así que su ámbito acaba antes del borrado.
    beats::DocumentManager docs;
    std::string error;
    if (!docs.AuthorizeWorkspaceRoot(ws.dir, error)) {
      std::cout << "[FAIL] No se autorizó el directorio temporal: " << error
                << "\n";
      return false;
    }
    beats::HunkManager mgr(docs);

    // 1. Accept Hunk 1
    accepted = mgr.AcceptHunk(ws.file1, 1, origContent, hunks, outContent1);
    // 2. Reject Hunk 2
    rejected = mgr.RejectHunk(ws.file2, 2, origContent, hunks, outContent2);
  }

  // Se borra el temporal ANTES de comprobar: si un assert aborta, no queda
  // rastro ni en el directorio de trabajo ni en el temporal.
  ws.Cleanup();

  DA_CHECK(accepted);
  DA_CHECK(outContent1 == "Line 1\nLine 2 ACCEPTED\nLine 3\n");
  std::cout << "[PASS] Accept hunk test\n";

  DA_CHECK(rejected);
  DA_CHECK(outContent2 == origContent);
  std::cout << "[PASS] Reject hunk test\n";

  return true;
}

// aceptar/rechazar un hunk aplica solo SU rango de líneas; un
// hunkId inexistente o un archivo modificado desde el diff no escriben nada.
bool test_hunk_range_application() {
  TempWorkspace ws;
  if (!ws.Create()) {
    std::cout << "[FAIL] No se pudo crear el directorio temporal\n";
    return false;
  }

  const std::string origContent = "L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9\n";
  if (!WriteFixture(ws.file1, origContent) ||
      !WriteFixture(ws.file2, "L1 CHANGED\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9\n") ||
      !WriteFixture(ws.file3, origContent)) {
    std::cout << "[FAIL] No se pudieron crear los ficheros de la prueba\n";
    return false;
  }

  beats::Hunk hunk1;
  hunk1.id = 1;
  hunk1.startLine = 1;
  hunk1.originalLineCount = 1;
  hunk1.newLineCount = 1;
  hunk1.originalContent = "L1";
  hunk1.newContent = "L1 CHANGED";

  beats::Hunk hunk2;
  hunk2.id = 2;
  hunk2.startLine = 4;
  hunk2.originalLineCount = 1;
  hunk2.newLineCount = 1;
  hunk2.originalContent = "L4";
  hunk2.newContent = "L4 CHANGED";

  beats::Hunk hunk3;
  hunk3.id = 3;
  hunk3.startLine = 7;
  hunk3.originalLineCount = 1;
  hunk3.newLineCount = 1;
  hunk3.originalContent = "L7";
  hunk3.newContent = "L7 CHANGED";

  const std::vector<beats::Hunk> hunks = {hunk1, hunk2, hunk3};

  bool accepted = false;
  bool rejected = false;
  bool missingRejected = false;
  bool changedRejected = false;
  std::string acceptedOut;
  std::string rejectedOut;
  std::string missingOut;
  std::string changedOut;
  {
    beats::DocumentManager docs;
    std::string error;
    if (!docs.AuthorizeWorkspaceRoot(ws.dir, error)) {
      std::cout << "[FAIL] No se autorizó el directorio temporal: " << error
                << "\n";
      return false;
    }
    beats::HunkManager mgr(docs);

    // Aceptar el hunk 2 deja el 1 y el 3 sin aplicar.
    accepted = mgr.AcceptHunk(ws.file1, 2, origContent, hunks, acceptedOut);

    // Rechazar el hunk 1 revierte solo su línea (la 1) y no toca las demás.
    rejected = mgr.RejectHunk(ws.file2, 1, origContent, hunks, rejectedOut);

    // hunkId inexistente: error y el archivo intacto.
    missingRejected =
        !mgr.AcceptHunk(ws.file3, 99, origContent, hunks, missingOut);

    // El archivo cambió desde el diff en el rango del hunk 2: error sin
    // escribir.
    DA_CHECK(
        WriteFixture(ws.file3, "L1\nL2\nL3\nL4 EXTERNO\nL5\nL6\nL7\nL8\nL9\n"));
    changedRejected =
        !mgr.AcceptHunk(ws.file3, 2, origContent, hunks, changedOut);
  }

  std::string file1After;
  std::string file2After;
  std::string file3After;
  const bool read = ReadFixture(ws.file1, file1After) &&
                    ReadFixture(ws.file2, file2After) &&
                    ReadFixture(ws.file3, file3After);
  ws.Cleanup();

  DA_CHECK(accepted);
  DA_CHECK(acceptedOut == "L1\nL2\nL3\nL4 CHANGED\nL5\nL6\nL7\nL8\nL9\n");
  DA_CHECK(read && file1After == acceptedOut);
  std::cout << "[PASS] Accept hunk applies only its own range\n";

  DA_CHECK(rejected);
  DA_CHECK(rejectedOut == origContent);
  DA_CHECK(read && file2After == origContent);
  std::cout << "[PASS] Reject hunk leaves the other hunks untouched\n";

  DA_CHECK(missingRejected);
  DA_CHECK(read &&
           file3After == "L1\nL2\nL3\nL4 EXTERNO\nL5\nL6\nL7\nL8\nL9\n");
  std::cout << "[PASS] Missing hunk id fails without writing\n";

  DA_CHECK(changedRejected);
  DA_CHECK(read &&
           file3After == "L1\nL2\nL3\nL4 EXTERNO\nL5\nL6\nL7\nL8\nL9\n");
  std::cout << "[PASS] Changed file fails without writing\n";

  return true;
}

// r2: aceptar y luego rechazar hunks cuyos conteos de lineas
// difieren (1->3, 3->1, solo borrado N->0 y solo insercion 0->N) restaura el
// archivo original exacto y deja el hunk vecino sin alterar.
bool test_hunk_multiline_reject_roundtrip() {
  TempWorkspace ws;
  if (!ws.Create()) {
    std::cout << "[FAIL] No se pudo crear el directorio temporal\n";
    return false;
  }

  const std::string origContent = "L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9\n";
  if (!WriteFixture(ws.file1, origContent) ||
      !WriteFixture(ws.file2, origContent) ||
      !WriteFixture(ws.file3, origContent) ||
      !WriteFixture(ws.file4, origContent)) {
    std::cout << "[FAIL] No se pudieron crear los ficheros de la prueba\n";
    return false;
  }

  // Hunk vecino comun: cambia la linea 8. Se acepta al final de cada caso para
  // comprobar que el fichero quedo en estado original y sigue utilizable.
  beats::Hunk neighbor;
  neighbor.id = 20;
  neighbor.startLine = 8;
  neighbor.originalLineCount = 1;
  neighbor.newLineCount = 1;
  neighbor.originalContent = "L8";
  neighbor.newContent = "L8 NEIGHBOR";

  // Caso 1 (fichero 1): hunk 1 -> 3 lineas.
  beats::Hunk grow;
  grow.id = 1;
  grow.startLine = 4;
  grow.originalLineCount = 1;
  grow.newLineCount = 3;
  grow.originalContent = "L4";
  grow.newContent = "L4a\nL4b\nL4c";

  // Caso 2 (fichero 2): hunk 3 -> 1 linea.
  beats::Hunk shrink;
  shrink.id = 2;
  shrink.startLine = 4;
  shrink.originalLineCount = 3;
  shrink.newLineCount = 1;
  shrink.originalContent = "L4\nL5\nL6";
  shrink.newContent = "L4-6 COMPACT";

  // Caso 3 (fichero 3): hunk que solo borro (2 -> 0 lineas).
  beats::Hunk deletion;
  deletion.id = 3;
  deletion.startLine = 4;
  deletion.originalLineCount = 2;
  deletion.newLineCount = 0;
  deletion.originalContent = "L4\nL5";
  deletion.newContent = "";

  // Caso 4 (fichero 4): hunk que solo inserto (0 -> 2 lineas).
  beats::Hunk insertion;
  insertion.id = 4;
  insertion.startLine = 4;
  insertion.originalLineCount = 0;
  insertion.newLineCount = 2;
  insertion.originalContent = "";
  insertion.newContent = "X1\nX2";

  const std::vector<beats::Hunk> growHunks = {grow, neighbor};
  const std::vector<beats::Hunk> shrinkHunks = {shrink, neighbor};
  const std::vector<beats::Hunk> deletionHunks = {deletion, neighbor};
  const std::vector<beats::Hunk> insertionHunks = {insertion, neighbor};

  bool growAccept = false;
  bool growReject = false;
  bool growNeighbor = false;
  bool shrinkAccept = false;
  bool shrinkReject = false;
  bool shrinkNeighbor = false;
  bool deletionAccept = false;
  bool deletionReject = false;
  bool deletionNeighbor = false;
  bool insertionAccept = false;
  bool insertionReject = false;
  bool insertionNeighbor = false;
  const std::string afterGrowAccept =
      "L1\nL2\nL3\nL4a\nL4b\nL4c\nL5\nL6\nL7\nL8\nL9\n";
  const std::string afterShrinkAccept =
      "L1\nL2\nL3\nL4-6 COMPACT\nL7\nL8\nL9\n";
  const std::string afterDeletionAccept = "L1\nL2\nL3\nL6\nL7\nL8\nL9\n";
  const std::string afterInsertionAccept =
      "L1\nL2\nL3\nX1\nX2\nL4\nL5\nL6\nL7\nL8\nL9\n";
  std::string growAcceptOut;
  std::string growRejectOut;
  std::string growNeighborOut;
  std::string shrinkAcceptOut;
  std::string shrinkRejectOut;
  std::string shrinkNeighborOut;
  std::string deletionAcceptOut;
  std::string deletionRejectOut;
  std::string deletionNeighborOut;
  std::string insertionAcceptOut;
  std::string insertionRejectOut;
  std::string insertionNeighborOut;
  {
    beats::DocumentManager docs;
    std::string error;
    if (!docs.AuthorizeWorkspaceRoot(ws.dir, error)) {
      std::cout << "[FAIL] No se autorizó el directorio temporal: " << error
                << "\n";
      return false;
    }
    beats::HunkManager mgr(docs);

    // Caso 1: 1->3. Acepta, comprueba el archivo completo, rechaza y vuelve a
    // comprobar; despues el vecino aun se puede aplicar.
    growAccept =
        mgr.AcceptHunk(ws.file1, 1, origContent, growHunks, growAcceptOut);
    if (growAccept)
      growReject =
          mgr.RejectHunk(ws.file1, 1, origContent, growHunks, growRejectOut);
    if (growReject)
      growNeighbor =
          mgr.AcceptHunk(ws.file1, 20, origContent, growHunks, growNeighborOut);

    // Caso 2: 3->1.
    shrinkAccept =
        mgr.AcceptHunk(ws.file2, 2, origContent, shrinkHunks, shrinkAcceptOut);
    if (shrinkAccept)
      shrinkReject = mgr.RejectHunk(ws.file2, 2, origContent, shrinkHunks,
                                    shrinkRejectOut);
    if (shrinkReject)
      shrinkNeighbor = mgr.AcceptHunk(ws.file2, 20, origContent, shrinkHunks,
                                      shrinkNeighborOut);

    // Caso 3: solo borrado (2->0).
    deletionAccept = mgr.AcceptHunk(ws.file3, 3, origContent, deletionHunks,
                                    deletionAcceptOut);
    if (deletionAccept)
      deletionReject = mgr.RejectHunk(ws.file3, 3, origContent, deletionHunks,
                                      deletionRejectOut);
    if (deletionReject)
      deletionNeighbor = mgr.AcceptHunk(ws.file3, 20, origContent,
                                        deletionHunks, deletionNeighborOut);

    // Caso 4: solo insercion (0->2).
    insertionAccept = mgr.AcceptHunk(ws.file4, 4, origContent, insertionHunks,
                                     insertionAcceptOut);
    if (insertionAccept)
      insertionReject = mgr.RejectHunk(ws.file4, 4, origContent, insertionHunks,
                                       insertionRejectOut);
    if (insertionReject)
      insertionNeighbor = mgr.AcceptHunk(ws.file4, 20, origContent,
                                         insertionHunks, insertionNeighborOut);
  }

  std::string file1After;
  std::string file2After;
  std::string file3After;
  std::string file4After;
  const bool read =
      ReadFixture(ws.file1, file1After) && ReadFixture(ws.file2, file2After) &&
      ReadFixture(ws.file3, file3After) && ReadFixture(ws.file4, file4After);
  ws.Cleanup();

  const std::string neighborApplied =
      "L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8 NEIGHBOR\nL9\n";

  // Caso 1 (1->3): el archivo completo se comprueba en cada paso y el vecino
  // no cambia.
  DA_CHECK(growAccept);
  DA_CHECK(growAcceptOut == afterGrowAccept);
  DA_CHECK(growReject);
  DA_CHECK(growRejectOut == origContent);
  DA_CHECK(growNeighbor);
  DA_CHECK(growNeighborOut == neighborApplied);
  DA_CHECK(read && file1After == growNeighborOut);
  std::cout << "[PASS] Accept+reject hunk 1->3 restores the file\n";

  // Caso 2 (3->1).
  DA_CHECK(shrinkAccept);
  DA_CHECK(shrinkAcceptOut == afterShrinkAccept);
  DA_CHECK(shrinkReject);
  DA_CHECK(shrinkRejectOut == origContent);
  DA_CHECK(shrinkNeighbor);
  DA_CHECK(shrinkNeighborOut == neighborApplied);
  DA_CHECK(read && file2After == shrinkNeighborOut);
  std::cout << "[PASS] Accept+reject hunk 3->1 restores the file\n";

  // Caso 3 (solo borrado, 2->0).
  DA_CHECK(deletionAccept);
  DA_CHECK(deletionAcceptOut == afterDeletionAccept);
  DA_CHECK(deletionReject);
  DA_CHECK(deletionRejectOut == origContent);
  DA_CHECK(deletionNeighbor);
  DA_CHECK(deletionNeighborOut == neighborApplied);
  DA_CHECK(read && file3After == deletionNeighborOut);
  std::cout << "[PASS] Accept+reject deletion-only hunk (2->0)\n";

  // Caso 4 (solo insercion, 0->2).
  DA_CHECK(insertionAccept);
  DA_CHECK(insertionAcceptOut == afterInsertionAccept);
  DA_CHECK(insertionReject);
  DA_CHECK(insertionRejectOut == origContent);
  DA_CHECK(insertionNeighbor);
  DA_CHECK(insertionNeighborOut == neighborApplied);
  DA_CHECK(read && file4After == insertionNeighborOut);
  std::cout << "[PASS] Accept+reject insertion-only hunk (0->2)\n";

  return true;
}

// r3: rechazo de hunks de solo borrado (N->0). Aceptar y rechazar
// uno colocado al FINAL del archivo restaura el original exacto (los limites
// se validan segun el estado que se revierte: el rango a comprobar es el de
// newCount lineas, que puede caer justo en el final, posicion == numero de
// lineas) y rechazar uno interno cuando el archivo cambio alrededor falla SIN
// escribir. Se usan comprobaciones impresas y un unico assert final para que
// la corrida roja muestre los dos casos antes del aborto.
bool test_hunk_deleteonly_reject_context() {
  TempWorkspace ws;
  if (!ws.Create()) {
    std::cout << "[FAIL] No se pudo crear el directorio temporal\n";
    return false;
  }

  const std::string origContent = "L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9\n";
  if (!WriteFixture(ws.file1, origContent) ||
      !WriteFixture(ws.file2, origContent)) {
    std::cout << "[FAIL] No se pudieron crear los ficheros de la prueba\n";
    return false;
  }

  // Hunk de solo borrado al final del archivo (quita L8 y L9).
  beats::Hunk tail;
  tail.id = 1;
  tail.startLine = 8;
  tail.originalLineCount = 2;
  tail.newLineCount = 0;
  tail.originalContent = "L8\nL9";
  tail.newContent = "";

  // Hunk de solo borrado interno (quita L4 y L5).
  beats::Hunk mid;
  mid.id = 2;
  mid.startLine = 4;
  mid.originalLineCount = 2;
  mid.newLineCount = 0;
  mid.originalContent = "L4\nL5";
  mid.newContent = "";

  bool tailAccept = false;
  bool tailReject = false;
  bool midAccept = false;
  bool midReject = true;
  std::string tailAcceptOut;
  std::string tailRejectOut;
  std::string midAcceptOut;
  std::string midRejectOut;
  std::string midError;
  {
    beats::DocumentManager docs;
    std::string error;
    if (!docs.AuthorizeWorkspaceRoot(ws.dir, error)) {
      std::cout << "[FAIL] No se autorizó el directorio temporal: " << error
                << "\n";
      return false;
    }
    beats::HunkManager mgr(docs);
    const std::vector<beats::Hunk> tailHunks = {tail};
    const std::vector<beats::Hunk> midHunks = {mid};

    // Caso 1: aceptar y rechazar el hunk de solo borrado al final.
    tailAccept =
        mgr.AcceptHunk(ws.file1, 1, origContent, tailHunks, tailAcceptOut);
    if (tailAccept)
      tailReject =
          mgr.RejectHunk(ws.file1, 1, origContent, tailHunks, tailRejectOut);

    // Caso 2: aceptar el hunk interno, cambiar el archivo alrededor y
    // rechazar: debe dar error sin escribir y dejar el archivo sin cambios.
    midAccept =
        mgr.AcceptHunk(ws.file2, 2, origContent, midHunks, midAcceptOut);
    if (midAccept) {
      WriteFixture(ws.file2, "L1\nL2\nL3 CAMBIADA\nL6 CAMBIADA\nL7\nL8\nL9\n");
      midReject = mgr.RejectHunk(ws.file2, 2, origContent, midHunks,
                                 midRejectOut, &midError);
    }
  }

  std::string file1After;
  std::string file2After;
  const bool read =
      ReadFixture(ws.file1, file1After) && ReadFixture(ws.file2, file2After);

  ws.Cleanup();

  bool ok = true;
  const std::string afterTailAccept = "L1\nL2\nL3\nL4\nL5\nL6\nL7\n";
  const std::string afterMidAccept = "L1\nL2\nL3\nL6\nL7\nL8\nL9\n";
  const std::string midChanged =
      "L1\nL2\nL3 CAMBIADA\nL6 CAMBIADA\nL7\nL8\nL9\n";

  if (tailAccept && tailAcceptOut == afterTailAccept) {
    std::cout << "[PASS] Accept deletion-only hunk at end of file\n";
  } else {
    std::cout << "[FAIL] Accept deletion-only hunk at end of file (";
    std::cout << "accepted=" << tailAccept << ")\n";
    ok = false;
  }
  if (tailReject && tailRejectOut == origContent && read &&
      file1After == origContent) {
    std::cout << "[PASS] Reject deletion-only hunk at end restores original\n";
  } else {
    std::cout << "[FAIL] Reject deletion-only hunk at end restores original";
    std::cout << " (rejected=" << tailReject << ")\n";
    ok = false;
  }
  if (midAccept && midAcceptOut == afterMidAccept) {
    std::cout << "[PASS] Accept internal deletion-only hunk\n";
  } else {
    std::cout << "[FAIL] Accept internal deletion-only hunk\n";
    ok = false;
  }
  if (!midReject && !midError.empty() && read && file2After == midChanged) {
    std::cout << "[PASS] Reject of changed-around deletion-only hunk fails"
                 " without writing\n";
  } else {
    std::cout << "[FAIL] Reject of changed-around deletion-only hunk fails"
                 " without writing (rejected="
              << midReject << " error=\"" << midError << "\")\n";
    ok = false;
  }

  // El volcado explicito evita que abort() pierda los [PASS]/[FAIL] de la
  // corrida roja por buffering de stdout.
  std::cout << std::flush;
  DA_CHECK(ok);
  return ok;
}

} // namespace

int main() {
  if (!test_hunk_accept_reject_hash_verification())
    return 1;
  if (!test_hunk_range_application())
    return 1;
  if (!test_hunk_multiline_reject_roundtrip())
    return 1;
  if (!test_hunk_deleteonly_reject_context())
    return 1;
  std::cout << "ALL HUNK MANAGER TESTS PASSED!\n";
  return 0;
}
