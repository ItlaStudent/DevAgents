// Estas pruebas se apoyan en DA_CHECK(): ningún modo de optimización (NDEBUG)
// las puede compilar fuera. Debe ir antes de cualquier #include.
#include "document_manager.hpp"
#include "test_check.hpp"
#include <algorithm>
#include <atomic>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <thread>
#include <winioctl.h>

static std::wstring CurrentRoot() {
  wchar_t cwd[32768];
  const DWORD size = GetCurrentDirectoryW(32768, cwd);
  DA_CHECK(size && size < 32768);
  return std::wstring(cwd, size);
}

static void AuthorizeCurrentRoot(beats::DocumentManager &manager) {
  std::string error;
  DA_CHECK(manager.AuthorizeWorkspaceRoot(CurrentRoot(), error));
}

static void WriteFixture(const std::wstring &path, const std::string &text) {
  HANDLE handle = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  DA_CHECK(handle != INVALID_HANDLE_VALUE);
  DWORD written = 0;
  const bool ok =
      WriteFile(handle, text.data(), static_cast<DWORD>(text.size()), &written,
                nullptr) &&
      written == text.size();
  CloseHandle(handle);
  DA_CHECK(ok);
}

// Convierte un directorio VACÍO existente en un junction (con o sin otros
// handles abiertos sobre él, según su modo de compartición).
static bool ConvertToJunction(const std::wstring &path,
                              const std::wstring &target) {
  HANDLE handle = CreateFileW(
      path.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
      OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS,
      nullptr);
  if (handle == INVALID_HANDLE_VALUE)
    return false;
  const std::wstring substitute = L"\\??\\" + target;
  const WORD substituteBytes = static_cast<WORD>(substitute.size() * 2);
  const WORD targetBytes = static_cast<WORD>(target.size() * 2);
  std::vector<unsigned char> data(16 + substituteBytes + 2 + targetBytes + 2,
                                  0);
  const DWORD tag = IO_REPARSE_TAG_MOUNT_POINT;
  memcpy(data.data(), &tag, sizeof(tag));
  const WORD fields[] = {
      static_cast<WORD>(data.size() - 8),     0,          0, substituteBytes,
      static_cast<WORD>(substituteBytes + 2), targetBytes};
  memcpy(data.data() + 4, fields, sizeof(fields));
  memcpy(data.data() + 16, substitute.data(), substituteBytes);
  memcpy(data.data() + 18 + substituteBytes, target.data(), targetBytes);
  DWORD returned = 0;
  const bool ok = DeviceIoControl(handle, FSCTL_SET_REPARSE_POINT, data.data(),
                                  static_cast<DWORD>(data.size()), nullptr, 0,
                                  &returned, nullptr) != FALSE;
  CloseHandle(handle);
  return ok;
}

static bool MakeJunction(const std::wstring &path, const std::wstring &target) {
  return CreateDirectoryW(path.c_str(), nullptr) &&
         ConvertToJunction(path, target);
}

static void test_confined_save() {
  const std::wstring base = CurrentRoot();
  const std::wstring root = base + L"\\beats_doc_root";
  const std::wstring outside = base + L"\\beats_doc_root_evil";
  DA_CHECK(CreateDirectoryW(root.c_str(), nullptr));
  DA_CHECK(CreateDirectoryW(outside.c_str(), nullptr));
  const std::wstring victim = outside + L"\\sentinel.txt";
  WriteFixture(victim, "sentinel");
  const std::wstring junction = root + L"\\junction";
  DA_CHECK(
      MakeJunction(junction, outside)); // Actual NTFS junction, no mock/skip.
  const std::wstring hardlink = root + L"\\hardlink.txt";
  DA_CHECK(CreateHardLinkW(hardlink.c_str(), victim.c_str(), nullptr));
  {
    beats::DocumentManager manager;
    std::string error;
    DA_CHECK(manager.AuthorizeWorkspaceRoot(root, error));
    const std::vector<std::wstring> rejected = {
        root + L"\\..\\beats_doc_root_evil\\sentinel.txt",
        victim,
        root + L"\\junction\\sentinel.txt",
        hardlink,
        L"\\\\localhost\\C$\\tmp\\evil.txt",
        L"C:evil.txt",
        root + L"\\stream.txt:payload",
        L"\\\\?\\" + root + L"\\x.txt"};
    for (const auto &path : rejected)
      DA_CHECK(!manager.SaveDocument(path, "attack", true, error));
    beats::DocumentState observed;
    DA_CHECK(!manager.OpenDocument(victim, observed));
    std::ifstream sentinel(victim.c_str(), std::ios::binary);
    DA_CHECK(std::string(std::istreambuf_iterator<char>(sentinel), {}) ==
             "sentinel");
    sentinel.close();
    std::cout
        << "[PASS] 8 hostile paths denied; junction/hardlink victim intact\n";

    const std::wstring local = root + L"\\good.txt";
    DA_CHECK(manager.SaveDocument(local, "long content", true, error));
    DA_CHECK(manager.SaveDocument(local, "short", true, error));
    DA_CHECK(manager.OpenDocument(local, observed));
    DA_CHECK(observed.content == "short");
    DeleteFileW(local.c_str());
    std::cout << "[PASS] Workspace create/overwrite/truncation\n";

    std::string token;
    // Native dialog authority may choose one file outside open roots.
    DeleteFileW(hardlink.c_str());
    DA_CHECK(manager.AuthorizeSaveAs(victim, token, error));
    DA_CHECK(!token.empty());
    DA_CHECK(!manager.SaveDocument(root + L"\\wrong.txt", "attack", true, error,
                                   token));
    DA_CHECK(!manager.SaveDocument(victim, "attack", true, error, token));
    DA_CHECK(manager.AuthorizeSaveAs(victim, token, error));
    DA_CHECK(manager.SaveDocument(victim, "chosen", true, error, token));
    DA_CHECK(!manager.SaveDocument(victim, "replay", true, error, token));
    DA_CHECK(!manager.OpenDocument(victim, observed));
    DA_CHECK(manager.AuthorizeReadRoot(outside, error));
    DA_CHECK(manager.OpenDocument(victim, observed));
    DA_CHECK(observed.content == "chosen");
    DA_CHECK(
        !manager.SaveDocument(victim, "read grant is not write", true, error));
    DA_CHECK(!manager.AuthorizeSaveAs(root + L"\\junction\\sentinel.txt", token,
                                      error));
    std::cout << "[PASS] Save As token bound to path and consumed once\n";

    // Root ancestors remain pinned throughout the session (junction swap race).
    const std::wstring moved = base + L"\\beats_doc_root_moved";
    DA_CHECK(!MoveFileW(root.c_str(), moved.c_str()));
    DA_CHECK(GetLastError() == ERROR_SHARING_VIOLATION ||
             GetLastError() == ERROR_ACCESS_DENIED);
    std::cout << "[PASS] Root replacement denied while authorized\n";
    // Sin FILE_SHARE_DELETE: ni borrar ni renombrar el componente retenido.
    HANDLE remove = CreateFileW(
        root.c_str(), DELETE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    DA_CHECK(remove == INVALID_HANDLE_VALUE);
    DA_CHECK(GetLastError() == ERROR_SHARING_VIOLATION);
    std::cout << "[PASS] Retained root cannot be opened for delete/rename\n";
    // Los handles de sesión comparten WRITE (ALTO-1): un directorio VACÍO
    // retenido sí puede convertirse en junction por otro proceso. La
    // protección es entonces la validación en cada uso, no el bloqueo: el host
    // debe fallar cerrado y no escribir fuera.
    const std::wstring emptyRoot = base + L"\\beats_doc_root_empty";
    DA_CHECK(CreateDirectoryW(emptyRoot.c_str(), nullptr));
    {
      beats::DocumentManager swapped;
      DA_CHECK(swapped.AuthorizeWorkspaceRoot(emptyRoot, error));
      DA_CHECK(ConvertToJunction(emptyRoot, outside));
      const std::wstring escaped = emptyRoot + L"\\sentinel.txt";
      DA_CHECK(!swapped.SaveDocument(escaped, "attack", true, error));
      DA_CHECK(!swapped.WriteWorkspaceFile(escaped, "attack", error));
      DA_CHECK(
          !swapped.CreateWorkspaceEntry(emptyRoot, L"made", true, "", error));
      DA_CHECK(!swapped.CreateWorkspaceEntry(emptyRoot, L"made.txt", false, "x",
                                             error));
      std::string content;
      DA_CHECK(!swapped.ReadWorkspaceFile(escaped, content));
      beats::confined::LockedPath locked;
      DA_CHECK(!swapped.LockReadDirectory(emptyRoot, locked));
    }
    DA_CHECK(GetFileAttributesW((outside + L"\\made").c_str()) ==
             INVALID_FILE_ATTRIBUTES);
    DA_CHECK(GetFileAttributesW((outside + L"\\made.txt").c_str()) ==
             INVALID_FILE_ATTRIBUTES);
    DA_CHECK(RemoveDirectoryW(emptyRoot.c_str()));
    std::cout << "[PASS] Retained root swapped for a junction fails closed "
                 "on every use (Validate, not sharing)\n";
  }
  DA_CHECK(RemoveDirectoryW(junction.c_str()));
  DA_CHECK(DeleteFileW(victim.c_str()));
  DA_CHECK(RemoveDirectoryW(root.c_str()));
  DA_CHECK(RemoveDirectoryW(outside.c_str()));
}

static void test_unc_path_policy() {
  std::wstring path;
  const std::wstring root = L"\\\\beats-security-no-smb.invalid\\workspace";
  const std::wstring file = root + L"\\nested\\document.txt";
  DA_CHECK(beats::confined::Absolute(root, path) && path == root);
  DA_CHECK(beats::confined::Absolute(root + L"\\", path) && path == root);
  DA_CHECK(
      beats::confined::HandleName(
          L"\\\\?\\UNC\\beats-security-no-smb.invalid\\workspace\\", path) &&
      path == root);
  DA_CHECK(beats::confined::VolumePrefixLength(root) == root.size());
  DA_CHECK(beats::confined::Absolute(file, path) && path == file);
  DA_CHECK(beats::confined::VolumePrefixLength(file) == root.size());
  DA_CHECK(beats::confined::Inside(root, file));
  DA_CHECK(!beats::confined::Inside(root, root + L"_evil\\document.txt"));
  const std::wstring extended = L"\\\\?\\UNC\\beats-security-no-smb."
                                L"invalid\\workspace\\nested\\document.txt";
  DA_CHECK(beats::confined::Extended(file) == extended);
  DA_CHECK(beats::confined::HandleName(extended, path) && path == file);
  DA_CHECK(
      beats::confined::HandleName(L"\\\\?\\C:\\workspace\\file.txt", path) &&
      path == L"C:\\workspace\\file.txt");
  const std::vector<std::wstring> rejected = {
      L"\\\\server",
      L"\\\\server\\",
      L"\\\\\\share\\file.txt",
      L"\\\\server\\\\file.txt",
      root + L"\\..\\outside.txt",
      root + L"\\file.txt:stream",
      L"\\\\?\\UNC\\server\\share\\file.txt",
      L"\\\\.\\UNC\\server\\share\\file.txt",
      root + L"\\alias.\\file.txt",
      root + L"\\alias \\file.txt",
      root + L"\\.\\file.txt"};
  for (const auto &input : rejected)
    DA_CHECK(!beats::confined::Absolute(input, path));
  DA_CHECK(
      !beats::confined::HandleName(L"\\\\?\\GLOBALROOT\\Device\\file", path));

  // No authorized root/token: return before LockParents and any network IO.
  // Real native UNC selection/SMB handle behavior remains NO_VERIFICADO.
  beats::DocumentManager manager;
  std::string error;
  DA_CHECK(!manager.SaveDocument(file, "untrusted", true, error));
  DA_CHECK(error.rfind("E_SAVE_NOT_AUTHORIZED", 0) == 0);
  std::cout << "[PASS] UNC syntax, handle names and 11 invalid names; "
               "unregistered UNC denied before filesystem IO\n";
}

// Lote 1 (SEC-WEBVIEW): los nombres de dispositivo Win32 (NUL, CON, PRN, AUX,
// COM1-9, LPT1-9, con o sin extensión, con punto/espacio final, como hoja,
// como componente intermedio, en la raíz de la unidad o bajo \\.\ y \\?\)
// nunca llegan al sistema de archivos por NINGUNA primitiva confinada que usan
// doc.open, doc.save, fs.list, fs.mkdir, fs.createFile, search.replace,
// hunk.accept/reject, checkpoint.* y los diálogos nativos. Una implementación
// sin confinamiento escribiría en el dispositivo (descartando los datos) o
// leería de CON/pipes (colgándose); aquí la comprobación es que todo se rechaza
// sin crear entradas.
static size_t CountEntries(const std::wstring &directory) {
  WIN32_FIND_DATAW data{};
  HANDLE find =
      FindFirstFileW((L"\\\\?\\" + directory + L"\\*").c_str(), &data);
  DA_CHECK(find != INVALID_HANDLE_VALUE);
  size_t count = 0;
  do {
    if (wcscmp(data.cFileName, L".") != 0 && wcscmp(data.cFileName, L"..") != 0)
      ++count;
  } while (FindNextFileW(find, &data));
  FindClose(find);
  return count;
}

static void test_win32_device_names_denied_everywhere() {
  const std::wstring root = CurrentRoot() + L"\\beats_doc_devices";
  DA_CHECK(CreateDirectoryW(root.c_str(), nullptr));
  const std::wstring outside = CurrentRoot() + L"\\beats_doc_devices_out";
  DA_CHECK(CreateDirectoryW(outside.c_str(), nullptr));
  const std::vector<std::wstring> devices = {
      L"NUL",           L"CON",
      L"NUL.txt",       L"nul.tar.gz",
      L"PRN",           L"AUX",
      L"COM1",          L"com9.log",
      L"LPT1",          L"LPT9.txt",
      L"NUL.",          L"NUL ",
      L"CON.",          L"sub\\NUL",
      L"sub\\CON.txt",  L"NUL\\child.txt",
      L"CON\\x\\y.txt", L"x.txt:$DATA",
      L"x:NUL",         L"..\\beats_doc_devices_out\\NUL"};
  std::vector<std::wstring> paths;
  for (const auto &device : devices)
    paths.push_back(root + L"\\" + device);
  for (const auto &device : {L"\\\\.\\NUL",
                             L"\\\\.\\CON",
                             L"\\\\.\\COM1",
                             L"\\\\.\\C:",
                             L"\\\\.\\PhysicalDrive0",
                             L"\\\\.\\pipe\\beats-no-pipe",
                             L"\\\\.\\GLOBALROOT\\Device\\Null",
                             L"\\\\?\\GLOBALROOT\\Device\\Null",
                             L"\\\\?\\C:\\NUL",
                             L"\\\\?\\UNC\\localhost\\C$\\NUL",
                             L"\\\\localhost\\C$\\NUL",
                             L"\\\\localhost\\C$\\CON.txt",
                             L"NUL",
                             L"CON",
                             L"C:NUL",
                             L"C:\\NUL",
                             L"C:\\CON",
                             L"C:/NUL",
                             L"c:\\nul.txt",
                             L"C:\\Windows\\..\\NUL",
                             L"//./NUL",
                             L"\\\\?\\"
                             L"NUL"})
    paths.push_back(device);
  // Con barras normales (el puente las normaliza) el resultado es idéntico.
  const size_t plain = paths.size();
  for (size_t i = 0; i < plain; ++i) {
    auto slashed = paths[i];
    std::replace(slashed.begin(), slashed.end(), L'\\', L'/');
    paths.push_back(std::move(slashed));
  }
  std::wstring canonical;
  for (const auto &path : paths)
    DA_CHECK(!beats::confined::Absolute(path, canonical));
  {
    beats::DocumentManager manager;
    std::string error;
    DA_CHECK(manager.AuthorizeWorkspaceRoot(root, error));
    DA_CHECK(manager.AuthorizeReadRoot(outside, error));
    beats::DocumentState doc;
    std::string content;
    std::string token;
    for (const auto &path : paths) {
      DA_CHECK(!manager.IsWorkspacePath(path));
      DA_CHECK(!manager.IsWritableWorkspacePath(path));
      DA_CHECK(!manager.OpenDocument(path, doc));
      DA_CHECK(!manager.ReadWorkspaceFile(path, content) && content.empty());
      DA_CHECK(!manager.SaveDocument(path, "attack", true, error));
      DA_CHECK(!manager.WriteWorkspaceFile(path, "attack", error));
      beats::confined::LockedPath locked;
      DA_CHECK(!manager.LockReadDirectory(path, locked));
      DA_CHECK(!manager.AuthorizeWorkspaceRoot(path, error));
      DA_CHECK(!manager.AuthorizeReadRoot(path, error));
      DA_CHECK(!manager.AuthorizeSaveAs(path, token, error) && token.empty());
      DA_CHECK(!manager.IsAuthorizedWorkspaceRoot(path));
      // Como carpeta padre (fs.mkdir/fs.createFile con parent hostil) y como
      // nombre de hoja bajo una raíz concedida (fs.mkdir/fs.createFile name).
      DA_CHECK(
          !manager.CreateWorkspaceEntry(path, L"blocked", true, "", error));
      DA_CHECK(!manager.CreateWorkspaceEntry(path, L"blocked.txt", false, "x",
                                             error));
    }
    for (const auto &leaf :
         {L"NUL", L"CON", L"PRN", L"AUX", L"COM1", L"LPT1", L"nul.txt",
          L"com9.log", L"NUL.", L"NUL ", L"x:NUL", L"..", L"."}) {
      DA_CHECK(!manager.CreateWorkspaceEntry(root, leaf, true, "", error));
      DA_CHECK(!manager.CreateWorkspaceEntry(root, leaf, false, "x", error));
    }
    // La víctima legítima sigue sin concederse por estar "cerca".
    DA_CHECK(!manager.SaveDocument(outside + L"\\NUL", "attack", true, error));
  }
  DA_CHECK(CountEntries(root) == 0 && CountEntries(outside) == 0);
  DA_CHECK(RemoveDirectoryW(root.c_str()));
  DA_CHECK(RemoveDirectoryW(outside.c_str()));
  std::cout
      << "[PASS] Win32 device names (NUL/CON/PRN/AUX/COMn/LPTn, variants, "
         "\\\\.\\ and \\\\?\\ namespaces, UNC) denied on all "
      << paths.size() << " forms by every confined primitive; no entries "
      << "created\n";
}

void test_document_open_save_conflict() {
  beats::DocumentManager mgr;
  AuthorizeCurrentRoot(mgr);
  std::wstring testPath = CurrentRoot() + L"\\beats_test_doc.txt";

  // 1. Create a test file
  std::ofstream out("beats_test_doc.txt", std::ios::binary);
  out << "Line 1\r\nLine 2\r\nLine 3\r\n";
  out.close();

  // 2. Open document
  beats::DocumentState doc;
  bool opened = mgr.OpenDocument(testPath, doc);
  DA_CHECK(opened);
  DA_CHECK(doc.content == "Line 1\r\nLine 2\r\nLine 3\r\n");
  DA_CHECK(doc.lineEnding == "\r\n");
  DA_CHECK(doc.encoding == "UTF-8");
  DA_CHECK(!doc.isDirty);
  std::cout << "[PASS] Open document test\n";

  // 3. Save document
  std::string err;
  bool saved = mgr.SaveDocument(
      testPath, "Line 1\r\nLine 2 Updated\r\nLine 3\r\n", false, err);
  DA_CHECK(saved);
  DA_CHECK(err.empty());
  std::cout << "[PASS] Save document test\n";

  // 4. Verify save on disk
  beats::DocumentState doc2;
  mgr.OpenDocument(testPath, doc2);
  DA_CHECK(doc2.content == "Line 1\r\nLine 2 Updated\r\nLine 3\r\n");
  std::cout << "[PASS] Save verification test\n";

  // Clean up
  DeleteFileW(testPath.c_str());
}

void test_document_bom() {
  beats::DocumentManager mgr;
  AuthorizeCurrentRoot(mgr);
  std::wstring bomPath = CurrentRoot() + L"\\beats_test_bom.txt";
  std::wstring noBomPath = CurrentRoot() + L"\\beats_test_nobom.txt";

  // Create UTF-8 BOM file (0xEF, 0xBB, 0xBF + "Contenido con BOM")
  std::ofstream outBom("beats_test_bom.txt", std::ios::binary);
  unsigned char bom[] = {0xEF, 0xBB, 0xBF};
  outBom.write(reinterpret_cast<char *>(bom), 3);
  outBom << "Contenido con BOM";
  outBom.close();

  // Create UTF-8 no BOM file ("Contenido sin BOM")
  std::ofstream outNoBom("beats_test_nobom.txt", std::ios::binary);
  outNoBom << "Contenido sin BOM";
  outNoBom.close();

  // Test BOM file
  beats::DocumentState docBom;
  bool okBom = mgr.OpenDocument(bomPath, docBom);
  DA_CHECK(okBom);
  DA_CHECK(docBom.encoding == "UTF-8-BOM");
  DA_CHECK(docBom.content == "Contenido con BOM"); // BOM stripped
  std::cout << "[PASS] Open document UTF-8-BOM test (BOM consumed correctly)\n";

  // Test No BOM file
  beats::DocumentState docNoBom;
  bool okNoBom = mgr.OpenDocument(noBomPath, docNoBom);
  DA_CHECK(okNoBom);
  DA_CHECK(docNoBom.encoding == "UTF-8");
  DA_CHECK(docNoBom.content == "Contenido sin BOM");
  std::cout << "[PASS] Open document UTF-8 No-BOM test\n";

  DeleteFileW(bomPath.c_str());
  DeleteFileW(noBomPath.c_str());
}

// E3.17: archivo de editor >= 20 MB y un archivo binario. El document manager
// lee bytes crudos: el deber honesto es abrir TODO el archivo sin truncar y
// devolverlo byte a byte — incluidos NULs del binario.
void test_document_large_and_binary() {
  beats::DocumentManager mgr;
  AuthorizeCurrentRoot(mgr);
  std::wstring bigPath = CurrentRoot() + L"\\beats_e317_big.txt";
  std::wstring binPath = CurrentRoot() + L"\\beats_e317_bin.dat";

  // 20 MB de contenido determinista: bloques de 1 MB con marca de offset, así
  // un truncado silencioso o un salto se detecta por posición, no por tamaño.
  const size_t kBig = 20 * 1024 * 1024;
  std::string big;
  big.reserve(kBig);
  while (big.size() < kBig) {
    char block[64];
    int n = snprintf(block, sizeof(block), "%08zu|", big.size());
    big.append(block, n);
    size_t fill = std::min<size_t>(1024 * 1024, kBig - big.size());
    big.append(fill > static_cast<size_t>(n) ? fill - n : 0, 'x');
  }
  big.resize(kBig);
  {
    std::ofstream out("beats_e317_big.txt", std::ios::binary);
    out.write(big.data(), static_cast<std::streamsize>(big.size()));
  }

  beats::DocumentState doc;
  bool opened = mgr.OpenDocument(bigPath, doc);
  DA_CHECK(opened);
  DA_CHECK(doc.content.size() == kBig);
  // Integridad por posición: inicio, mitad y cola llevan su marca de offset.
  DA_CHECK(doc.content.compare(0, 9, "00000000|") == 0);
  size_t mid = kBig / 2;
  size_t mid_block = mid - (mid % (1024 * 1024));
  if (mid_block + 9 <= kBig) {
    char want[16];
    snprintf(want, sizeof(want), "%08zu|", mid_block);
    DA_CHECK(doc.content.compare(mid_block, 9, want) == 0);
  }
  // Save + reopen de 20 MB: el round-trip no puede perder ni un byte.
  std::string err;
  bool saved = mgr.SaveDocument(bigPath, doc.content, true, err);
  DA_CHECK(saved);
  beats::DocumentState doc2;
  DA_CHECK(mgr.OpenDocument(bigPath, doc2));
  DA_CHECK(doc2.content.size() == kBig);
  DA_CHECK(doc2.content == doc.content);
  std::cout << "[PASS] Open/save 20MB document test\n";

  // Binario real: los 256 valores de byte, NUL incluido — un lector de texto
  // que corte en NUL o "limpie" bytes devolvería menos de 256.
  {
    std::ofstream out("beats_e317_bin.dat", std::ios::binary);
    for (int b = 0; b < 256; ++b) {
      char c = static_cast<char>(b);
      out.write(&c, 1);
    }
  }
  beats::DocumentState bindoc;
  bool binOpened = mgr.OpenDocument(binPath, bindoc);
  DA_CHECK(binOpened);
  DA_CHECK(bindoc.content.size() == 256);
  for (int b = 0; b < 256; ++b) {
    DA_CHECK(static_cast<unsigned char>(bindoc.content[b]) == b);
  }
  std::cout << "[PASS] Open binary document test (256/256 bytes intactos)\n";

  DeleteFileW(bigPath.c_str());
  DeleteFileW(binPath.c_str());
}

// Ejecuta una orden de cmd.exe en OTRO proceso. Devuelve su código de salida.
static DWORD RunExternalCmd(const std::wstring &command) {
  wchar_t system[MAX_PATH];
  const UINT length = GetSystemDirectoryW(system, MAX_PATH);
  DA_CHECK(length && length < MAX_PATH);
  const std::wstring cmd = std::wstring(system, length) + L"\\cmd.exe";
  std::wstring line = L"\"" + cmd + L"\" /d /s /c \"" + command + L"\"";
  std::vector<wchar_t> buffer(line.begin(), line.end());
  buffer.push_back(0);
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION child{};
  DA_CHECK(CreateProcessW(cmd.c_str(), buffer.data(), nullptr, nullptr, FALSE,
                          CREATE_NO_WINDOW, nullptr, nullptr, &startup,
                          &child));
  DA_CHECK(WaitForSingleObject(child.hProcess, 20000) == WAIT_OBJECT_0);
  DWORD code = 1;
  DA_CHECK(GetExitCodeProcess(child.hProcess, &code));
  CloseHandle(child.hThread);
  CloseHandle(child.hProcess);
  return code;
}

static bool Exists(const std::wstring &path) {
  return GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

// ALTO-1: los handles retenidos durante la sesión comparten READ|WRITE sin
// DELETE. Otro proceso (renombrados atómicos, `git config`, Explorer) puede
// cambiar el CONTENIDO de la raíz y de sus ancestros, pero no renombrar ni
// borrar el componente retenido, que es lo que fija la ruta autorizada.
static void test_session_retention_allows_siblings_not_components() {
  wchar_t temp[MAX_PATH];
  DA_CHECK(GetTempPathW(MAX_PATH, temp));
  const std::wstring base = std::wstring(temp) + L"beats_retain_" +
                            std::to_wstring(GetCurrentProcessId());
  const std::wstring ancestor = base + L"\\anc";
  const std::wstring root = ancestor + L"\\root";
  const std::wstring emptyRoot = ancestor + L"\\emptyroot";
  DA_CHECK(CreateDirectoryW(base.c_str(), nullptr));
  DA_CHECK(CreateDirectoryW(ancestor.c_str(), nullptr));
  DA_CHECK(CreateDirectoryW(root.c_str(), nullptr));
  DA_CHECK(CreateDirectoryW(emptyRoot.c_str(), nullptr));
  WriteFixture(root + L"\\inner.txt", "inner");
  WriteFixture(ancestor + L"\\sibling.txt", "sibling");
  {
    beats::DocumentManager manager;
    std::string error;
    DA_CHECK(manager.AuthorizeWorkspaceRoot(root, error));
    DA_CHECK(manager.AuthorizeWorkspaceRoot(emptyRoot, error));
    // Contenido de la raíz y de un ancestro retenido: renombrable.
    DA_CHECK(RunExternalCmd(L"ren \"" + root + L"\\inner.txt\" inner2.txt") ==
             0);
    DA_CHECK(Exists(root + L"\\inner2.txt") && !Exists(root + L"\\inner.txt"));
    DA_CHECK(RunExternalCmd(L"ren \"" + ancestor +
                            L"\\sibling.txt\" sibling2.txt") == 0);
    DA_CHECK(Exists(ancestor + L"\\sibling2.txt"));
    // También se puede crear y mover (escritura atómica con .lock + rename).
    DA_CHECK(RunExternalCmd(L"copy /y nul \"" + ancestor +
                            L"\\created.lock\" >nul") == 0);
    DA_CHECK(RunExternalCmd(L"move /y \"" + ancestor + L"\\created.lock\" \"" +
                            ancestor + L"\\created.cfg\" >nul") == 0);
    DA_CHECK(Exists(ancestor + L"\\created.cfg"));
    // El propio componente retenido, no: ni renombrar ni borrar.
    DA_CHECK(RunExternalCmd(L"ren \"" + root + L"\" root2") != 0);
    DA_CHECK(Exists(root) && !Exists(ancestor + L"\\root2"));
    DA_CHECK(RunExternalCmd(L"ren \"" + ancestor + L"\" anc2") != 0);
    DA_CHECK(Exists(ancestor));
    DA_CHECK(RunExternalCmd(L"rmdir \"" + emptyRoot + L"\"") != 0);
    DA_CHECK(Exists(emptyRoot));
    DA_CHECK(RunExternalCmd(L"ren \"" + base + L"\" beats_retain_moved") != 0);
    DA_CHECK(Exists(base));
    std::cout << "[PASS] Retained root/ancestors: contents renamable, retained "
                 "components cannot be renamed or deleted\n";
  }
  // Con los handles cerrados todo vuelve a ser operable: limpieza propia.
  DeleteFileW((root + L"\\inner2.txt").c_str());
  DeleteFileW((ancestor + L"\\sibling2.txt").c_str());
  DeleteFileW((ancestor + L"\\created.cfg").c_str());
  RemoveDirectoryW(root.c_str());
  RemoveDirectoryW(emptyRoot.c_str());
  RemoveDirectoryW(ancestor.c_str());
  RemoveDirectoryW(base.c_str());
}

static std::string ReadWhole(const std::wstring &path) {
  std::ifstream in(path.c_str(), std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(in), {});
}

static size_t CountSaveTemporaries(const std::wstring &directory) {
  size_t count = 0;
  WIN32_FIND_DATAW data{};
  HANDLE find = FindFirstFileW((directory + L"\\*").c_str(), &data);
  if (find == INVALID_HANDLE_VALUE)
    return 0;
  do {
    if (beats::confined::IsSaveTemporaryName(data.cFileName))
      ++count;
  } while (FindNextFileW(find, &data));
  FindClose(find);
  return count;
}

// BAJO-5: doc.save (y por tanto búsqueda/hunks) escribe un archivo hermano y lo
// cambia por el destino con un único renombrado: un lector ve el contenido
// antiguo o el nuevo, nunca uno truncado, y un fallo deja el original intacto.
// Las garantías de confinamiento (handles retenidos, hardlinks, reparse
// points) se conservan.
static void test_atomic_save() {
  const std::wstring base = CurrentRoot();
  const std::wstring root = base + L"\\beats_atomic_root";
  const std::wstring outside = base + L"\\beats_atomic_outside";
  DA_CHECK(CreateDirectoryW(root.c_str(), nullptr));
  DA_CHECK(CreateDirectoryW(outside.c_str(), nullptr));
  {
    beats::DocumentManager manager;
    std::string error;
    DA_CHECK(manager.AuthorizeWorkspaceRoot(root, error));
    const std::wstring file = root + L"\\doc.txt";

    DA_CHECK(beats::confined::IsSaveTemporaryName(
        L".devagents-save-00ff00ff00ff00ff00ff00ff00ff00ff.tmp"));
    DA_CHECK(!beats::confined::IsSaveTemporaryName(L"doc.tmp"));
    DA_CHECK(!beats::confined::IsSaveTemporaryName(L".devagents-save-.tmp"));
    DA_CHECK(!beats::confined::IsSaveTemporaryName(L"x.devagents-save-1.tmp"));
    DA_CHECK(!beats::confined::IsSaveTemporaryName(L".devagents-save-1.txt"));

    // Crear, sobrescribir con un contenido más corto, sin restos.
    DA_CHECK(manager.SaveDocument(file, std::string(100000, 'L'), true, error));
    DA_CHECK(manager.SaveDocument(file, "short", true, error));
    DA_CHECK(ReadWhole(file) == "short");
    DA_CHECK(CountSaveTemporaries(root) == 0);
    // Atributos de usuario (oculto/sistema/archivo) sobreviven al reemplazo.
    DA_CHECK(SetFileAttributesW(file.c_str(), FILE_ATTRIBUTE_HIDDEN));
    DA_CHECK(manager.SaveDocument(file, "still hidden", true, error));
    DA_CHECK(ReadWhole(file) == "still hidden");
    DA_CHECK(GetFileAttributesW(file.c_str()) & FILE_ATTRIBUTE_HIDDEN);
    DA_CHECK(SetFileAttributesW(file.c_str(), FILE_ATTRIBUTE_NORMAL));
    std::cout << "[PASS] doc.save atomic: create/overwrite/truncate leave no "
                 "temporary and keep user attributes\n";

    // Atomicidad observable: un lector concurrente nunca ve contenido parcial.
    const std::string a(2 * 1024 * 1024, 'A');
    const std::string b(2 * 1024 * 1024, 'B');
    DA_CHECK(manager.SaveDocument(file, a, true, error));
    std::atomic<bool> stop{false};
    std::atomic<int> reads{0}, partial{0};
    std::thread reader([&] {
      while (!stop) {
        HANDLE h =
            CreateFileW(file.c_str(), GENERIC_READ,
                        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h == INVALID_HANDLE_VALUE)
          continue; // el renombrado puede cruzarse con una apertura
        std::string data(a.size() + 1, '\0');
        DWORD got = 0;
        const BOOL ok = ReadFile(
            h, data.data(), static_cast<DWORD>(data.size()), &got, nullptr);
        CloseHandle(h);
        data.resize(got);
        if (ok) {
          ++reads;
          if (data != a && data != b)
            ++partial;
        }
      }
    });
    for (int i = 0; i < 40; ++i)
      DA_CHECK(manager.SaveDocument(file, (i % 2) ? a : b, true, error));
    stop = true;
    reader.join();
    DA_CHECK(reads.load() > 0);
    DA_CHECK(partial.load() == 0);
    DA_CHECK(CountSaveTemporaries(root) == 0);
    std::cout << "[PASS] doc.save atomic: " << reads.load()
              << " concurrent reads saw only complete old/new content during "
                 "40 replacements\n";

    // Fallos: el original queda intacto y no queda archivo hermano.
    DA_CHECK(manager.SaveDocument(file, "original", true, error));
    DA_CHECK(SetFileAttributesW(file.c_str(), FILE_ATTRIBUTE_READONLY));
    DA_CHECK(!manager.SaveDocument(file, "overwrite read-only", true, error));
    DA_CHECK(error.find("E_SAVE_OPEN_FAILED") != std::string::npos);
    DA_CHECK(SetFileAttributesW(file.c_str(), FILE_ATTRIBUTE_NORMAL));
    DA_CHECK(ReadWhole(file) == "original");
    {
      // Otro proceso lo tiene abierto sin FILE_SHARE_DELETE: el reemplazo
      // falla completo (no se trunca ni se deja a medias).
      HANDLE holder =
          CreateFileW(file.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
      DA_CHECK(holder != INVALID_HANDLE_VALUE);
      DA_CHECK(!manager.SaveDocument(file, "replace while held", true, error));
      DA_CHECK(error.find("E_WRITE_INCOMPLETE") != std::string::npos);
      CloseHandle(holder);
    }
    DA_CHECK(ReadWhole(file) == "original");
    const std::wstring dir = root + L"\\adir";
    DA_CHECK(CreateDirectoryW(dir.c_str(), nullptr));
    DA_CHECK(!manager.SaveDocument(dir, "x", true, error));
    DA_CHECK(GetFileAttributesW(dir.c_str()) & FILE_ATTRIBUTE_DIRECTORY);
    DA_CHECK(RemoveDirectoryW(dir.c_str()));
    DA_CHECK(CountSaveTemporaries(root) == 0);
    DA_CHECK(manager.SaveDocument(file, "after failures", true, error));
    DA_CHECK(ReadWhole(file) == "after failures");
    std::cout << "[PASS] doc.save atomic: read-only, held-open and directory "
                 "targets fail with the original intact and no temporary\n";

    // Confinamiento intacto: hardlink y junction en la hoja se rechazan y la
    // víctima no cambia (el renombrado nunca escribe a través del destino).
    const std::wstring victim = outside + L"\\victim.txt";
    WriteFixture(victim, "victim");
    const std::wstring hardlink = root + L"\\link.txt";
    DA_CHECK(CreateHardLinkW(hardlink.c_str(), victim.c_str(), nullptr));
    DA_CHECK(!manager.SaveDocument(hardlink, "attack", true, error));
    DA_CHECK(!manager.WriteWorkspaceFile(hardlink, "attack", error));
    DA_CHECK(ReadWhole(victim) == "victim");
    DA_CHECK(DeleteFileW(hardlink.c_str()));
    const std::wstring leafJunction = root + L"\\leaf";
    DA_CHECK(MakeJunction(leafJunction, outside));
    DA_CHECK(!manager.SaveDocument(leafJunction, "attack", true, error));
    DA_CHECK(!manager.SaveDocument(leafJunction + L"\\victim.txt", "attack",
                                   true, error));
    DA_CHECK(ReadWhole(victim) == "victim");
    DA_CHECK(RemoveDirectoryW(leafJunction.c_str()));
    DA_CHECK(CountSaveTemporaries(root) == 0 &&
             CountSaveTemporaries(outside) == 0);
    DA_CHECK(DeleteFileW(victim.c_str()));
    std::cout << "[PASS] doc.save atomic keeps confinement: hardlink and "
                 "junction leaves rejected, victims intact\n";

    // Los handles retenidos siguen impidiendo renombrar la raíz.
    DA_CHECK(
        !MoveFileW(root.c_str(), (base + L"\\beats_atomic_moved").c_str()));
    DA_CHECK(DeleteFileW(file.c_str()));
  }
  DA_CHECK(RemoveDirectoryW(root.c_str()));
  DA_CHECK(RemoveDirectoryW(outside.c_str()));
}

static std::wstring EnvPath(const wchar_t *name) {
  wchar_t value[32768];
  const DWORD length = GetEnvironmentVariableW(name, value, 32768);
  return length && length < 32768 ? std::wstring(value, length)
                                  : std::wstring();
}

// MEDIO-4 / BAJO-6: dentro de una raíz concedida, el host no escribe en el
// bundle servido, el directorio del ejecutable, `.git` ni `.gitattributes`;
// la lectura (explorador) sigue funcionando.
static void test_protected_write_zones() {
  wchar_t temp[MAX_PATH];
  DA_CHECK(GetTempPathW(MAX_PATH, temp));
  const std::wstring root = std::wstring(temp) + L"beats_protected_" +
                            std::to_wstring(GetCurrentProcessId());
  const std::wstring dist = root + L"\\shell\\webui\\dist";
  const std::wstring exeDir = root + L"\\bin";
  const std::wstring gitDir = root + L"\\repo\\.git";
  DA_CHECK(CreateDirectoryW(root.c_str(), nullptr));
  for (const auto &dir :
       {root + L"\\shell", root + L"\\shell\\webui", dist, exeDir,
        root + L"\\repo", gitDir, root + L"\\repo\\sub"})
    DA_CHECK(CreateDirectoryW(dir.c_str(), nullptr));
  WriteFixture(dist + L"\\index.html", "<html></html>");
  WriteFixture(exeDir + L"\\host.exe", "MZ");
  WriteFixture(gitDir + L"\\config", "[core]\n");
  WriteFixture(root + L"\\repo\\.gitattributes", "* text\n");
  WriteFixture(root + L"\\repo\\sub\\ok.txt", "ok");
  {
    beats::DocumentManager manager;
    std::string error;
    DA_CHECK(manager.AuthorizeWorkspaceRoot(root, error));
    manager.DenyWritesBelow(dist);
    manager.DenyWritesBelow(exeDir);
    const std::wstring denied[] = {
        dist + L"\\index.html",          dist + L"\\new.js",
        exeDir + L"\\host.exe",          gitDir + L"\\config",
        gitDir + L"\\hooks\\pre-commit", root + L"\\repo\\.gitattributes",
        root + L"\\repo\\.GIT\\config",  root + L"\\repo\\sub\\.gitattributes"};
    for (const auto &path : denied) {
      DA_CHECK(!manager.IsWritableWorkspacePath(path));
      DA_CHECK(!manager.SaveDocument(path, "evil", true, error));
      DA_CHECK(error.rfind("E_SAVE_NOT_AUTHORIZED", 0) == 0);
      DA_CHECK(!manager.WriteWorkspaceFile(path, "evil", error));
    }
    DA_CHECK(!manager.CreateWorkspaceEntry(gitDir, L"hooks", true, "", error));
    DA_CHECK(
        !manager.CreateWorkspaceEntry(dist, L"evil.js", false, "x", error));
    std::string content;
    DA_CHECK(manager.ReadWorkspaceFile(gitDir + L"\\config", content) &&
             content == "[core]\n");
    DA_CHECK(manager.ReadWorkspaceFile(dist + L"\\index.html", content));
    // Lo demás sigue escribible.
    DA_CHECK(manager.IsWritableWorkspacePath(root + L"\\repo\\sub\\ok.txt"));
    DA_CHECK(manager.SaveDocument(root + L"\\repo\\sub\\ok.txt", "changed",
                                  true, error));
    DA_CHECK(manager.CreateWorkspaceEntry(root + L"\\repo\\sub", L"new.txt",
                                          false, "n", error));
    DA_CHECK(manager.CreateWorkspaceEntry(root + L"\\repo\\sub", L".gitignore",
                                          false, "*.tmp\n", error));
    DA_CHECK(manager.ReadWorkspaceFile(dist + L"\\index.html", content) &&
             content == "<html></html>");
    std::cout << "[PASS] Protected zones: bundle, exe dir, .git and "
                 ".gitattributes denied for writes, still readable\n";
  }
  DeleteFileW((root + L"\\repo\\sub\\new.txt").c_str());
  DeleteFileW((root + L"\\repo\\sub\\.gitignore").c_str());
  DeleteFileW((root + L"\\repo\\sub\\ok.txt").c_str());
  DeleteFileW((root + L"\\repo\\.gitattributes").c_str());
  DeleteFileW((gitDir + L"\\config").c_str());
  DeleteFileW((exeDir + L"\\host.exe").c_str());
  DeleteFileW((dist + L"\\index.html").c_str());
  for (const auto &dir :
       {root + L"\\repo\\sub", gitDir, root + L"\\repo", exeDir, dist,
        root + L"\\shell\\webui", root + L"\\shell", root})
    RemoveDirectoryW(dir.c_str());
}

static void test_broad_startup_roots_are_not_granted() {
  using beats::DocumentManager;
  const std::wstring profile = EnvPath(L"USERPROFILE");
  const std::wstring programFiles = EnvPath(L"ProgramFiles");
  wchar_t windows[MAX_PATH];
  const UINT windowsLength = GetWindowsDirectoryW(windows, MAX_PATH);
  DA_CHECK(!profile.empty() && !programFiles.empty() && windowsLength);
  const std::wstring windowsDir(windows, windowsLength);
  DA_CHECK(DocumentManager::IsBroadStartupRoot(profile));
  DA_CHECK(DocumentManager::IsBroadStartupRoot(windowsDir));
  DA_CHECK(DocumentManager::IsBroadStartupRoot(windowsDir + L"\\System32"));
  DA_CHECK(DocumentManager::IsBroadStartupRoot(programFiles));
  DA_CHECK(DocumentManager::IsBroadStartupRoot(programFiles + L"\\Git"));
  DA_CHECK(DocumentManager::IsBroadStartupRoot(L"C:\\"));
  DA_CHECK(DocumentManager::IsBroadStartupRoot(L"C:\\Users"));
  DA_CHECK(DocumentManager::IsBroadStartupRoot(L"\\\\server\\share"));
  DA_CHECK(DocumentManager::IsBroadStartupRoot(L"relative\\path"));
  // Un proyecto concreto dentro del perfil sí es un espacio de trabajo.
  DA_CHECK(!DocumentManager::IsBroadStartupRoot(profile + L"\\Proyectos\\app"));
  DA_CHECK(!DocumentManager::IsBroadStartupRoot(CurrentRoot()));
  std::cout << "[PASS] Broad startup roots (profile, Windows, Program Files, "
               "drive, ancestors) are not granted by default\n";
}

// AtomicWrite requires its immediate parent to be retained. Keep this fixture
// local to that primitive; DocumentManager separately tests all ancestors.
static void LockAtomicFixture(const std::wstring &file,
                              beats::confined::LockedPath &locked) {
  const auto parent = file.substr(0, file.find_last_of(L'\\'));
  HANDLE h = CreateFileW(
      beats::confined::Extended(parent).c_str(),
      FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES,
      beats::confined::kSessionDirectoryShare, nullptr, OPEN_EXISTING,
      FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  DA_CHECK(h != INVALID_HANDLE_VALUE);
  locked.handles.push_back(h);
  DA_CHECK(beats::confined::Validate(h, parent, true));
  locked.path = file;
}

static void test_seg011_h3_atomic() {
  const auto root = CurrentRoot() + L"\\beats_seg011_h3_atomic";
  DA_CHECK(CreateDirectoryW(root.c_str(), nullptr));
  const auto file = root + L"\\doc.txt";
  WriteFixture(file, "old");
  bool truthful = false;
  {
    beats::confined::LockedPath locked;
    LockAtomicFixture(file, locked);
    FILETIME modified{};
    beats::confined::atomicWriteHooks.verify = [](HANDLE, const std::wstring &,
                                                  FILETIME &) { return false; };
    const auto status = beats::confined::AtomicWrite(locked, "new", modified);
    beats::confined::atomicWriteHooks = {};
    DA_CHECK(ReadWhole(file) == "new" && CountSaveTemporaries(root) == 0);
    truthful = status == beats::confined::AtomicStatus::ReplacedUnverified;
    std::cout << "CK-SEG-011 H3 estado posterior al renombrado: "
              << (truthful ? "PASS" : "FAIL") << std::endl;
  }
  DA_CHECK(DeleteFileW(file.c_str()));
  DA_CHECK(RemoveDirectoryW(root.c_str()));
  DA_CHECK(truthful);
}

static void test_seg011_h4() {
  const auto root = CurrentRoot() + L"\\beats_seg011_h4";
  DA_CHECK(CreateDirectoryW(root.c_str(), nullptr));
  const auto file = root + L"\\doc.txt";
  bool passed = true;
  for (DWORD unsupported :
       {ERROR_INVALID_PARAMETER, ERROR_NOT_SUPPORTED, ERROR_INVALID_FUNCTION}) {
    WriteFixture(file, "original");
    static DWORD forcedError;
    static std::wstring swapped;
    forcedError = unsupported;
    swapped.clear();
    {
      beats::confined::LockedPath locked;
      LockAtomicFixture(file, locked);
      FILETIME modified{};
      beats::confined::atomicWriteHooks.rename =
          [](HANDLE, const std::wstring &) { return forcedError; };
      beats::confined::atomicWriteHooks.afterTemporaryClosed =
          [](const std::wstring &temporary) {
            swapped = temporary;
            DA_CHECK(
                MoveFileW(temporary.c_str(), (temporary + L".held").c_str()));
            WriteFixture(temporary, "impostor");
          };
      const auto status =
          beats::confined::AtomicWrite(locked, "authorized", modified);
      beats::confined::atomicWriteHooks = {};
      const bool intact =
          status == beats::confined::AtomicStatus::WriteFailed &&
          ReadWhole(file) == "original" &&
          ReadWhole(swapped + L".held") == "authorized" &&
          CountSaveTemporaries(root) == 0;
      passed = passed && intact;
      std::cout << "CK-SEG-011 H4 fallback no reemplaza con objeto sustituido ("
                << unsupported << "): " << (intact ? "PASS" : "FAIL")
                << std::endl;
      DA_CHECK(DeleteFileW((swapped + L".held").c_str()));
    }
    DA_CHECK(DeleteFileW(file.c_str()));
  }
  DA_CHECK(RemoveDirectoryW(root.c_str()));
  DA_CHECK(passed);
}

static void test_seg011_h7() {
  const auto root = CurrentRoot() + L"\\beats_seg011_h7";
  DA_CHECK(CreateDirectoryW(root.c_str(), nullptr));
  const auto file = root + L"\\doc.txt";
  bool passed = true;
  for (DWORD denied :
       {ERROR_ACCESS_DENIED, ERROR_SHARING_VIOLATION, ERROR_LOCK_VIOLATION}) {
    for (bool persistent : {false, true}) {
      WriteFixture(file, "original");
      static unsigned calls;
      static DWORD forcedError;
      static bool forcePersistent;
      calls = 0;
      forcedError = denied;
      forcePersistent = persistent;
      {
        beats::confined::LockedPath locked;
        LockAtomicFixture(file, locked);
        FILETIME modified{};
        beats::confined::atomicWriteHooks.rename =
            [](HANDLE h, const std::wstring &target) {
              ++calls;
              return forcePersistent || calls <= 2
                         ? forcedError
                         : beats::confined::RenameOverByHandle(h, target);
            };
        const auto status =
            beats::confined::AtomicWrite(locked, "new", modified);
        beats::confined::atomicWriteHooks = {};
        const bool correct =
            persistent
                ? status == beats::confined::AtomicStatus::WriteFailed &&
                      calls == 5 && ReadWhole(file) == "original"
                : status == beats::confined::AtomicStatus::Ok && calls == 3 &&
                      ReadWhole(file) == "new" &&
                      (modified.dwHighDateTime || modified.dwLowDateTime);
        const bool ok = correct && CountSaveTemporaries(root) == 0;
        passed = passed && ok;
        std::cout << "CK-SEG-011 H7 error " << denied
                  << (persistent ? " persistente" : " transitorio") << ": "
                  << (ok ? "PASS" : "FAIL") << "; intentos=" << calls
                  << std::endl;
      }
      DA_CHECK(DeleteFileW(file.c_str()));
    }
  }
  DA_CHECK(RemoveDirectoryW(root.c_str()));
  DA_CHECK(passed);
}

static void test_seg011_h3() {
  const auto root = CurrentRoot() + L"\\beats_seg011_h3";
  DA_CHECK(CreateDirectoryW(root.c_str(), nullptr));
  const auto file = root + L"\\doc.txt";
  bool truthful = false;
  {
    beats::DocumentManager manager;
    std::string error;
    DA_CHECK(manager.AuthorizeWorkspaceRoot(root, error));
    DA_CHECK(manager.SaveDocument(file, "old", true, error));
    beats::DocumentState dirty;
    DA_CHECK(manager.GetTracked(file, dirty));
    dirty.content = "new";
    dirty.isDirty = true;
    manager.KeepTrack(dirty);
    beats::confined::atomicWriteHooks.verify = [](HANDLE, const std::wstring &,
                                                  FILETIME &) { return false; };
    DA_CHECK(!manager.SaveDocument(file, "new", true, error));
    beats::confined::atomicWriteHooks = {};
    DA_CHECK(ReadWhole(file) == "new");
    DA_CHECK(CountSaveTemporaries(root) == 0);
    beats::DocumentState tracked;
    DA_CHECK(manager.GetTracked(file, tracked) && tracked.isDirty);
    truthful = error.find("E_SAVE_REPLACED_UNVERIFIED") != std::string::npos &&
               error.find("recargar") != std::string::npos &&
               error.find("No se escribi") == std::string::npos;
    std::cout << "CK-SEG-011 H3 fallo posterior al renombrado: "
              << (truthful ? "PASS" : "FAIL") << "; " << error << std::endl;
    DA_CHECK(manager.OpenDocument(file, tracked) && tracked.content == "new" &&
             !tracked.isDirty);
  }
  DA_CHECK(DeleteFileW(file.c_str()));
  DA_CHECK(RemoveDirectoryW(root.c_str()));
  DA_CHECK(truthful);
}

static void test_vg2_workspace_activation() {
  wchar_t temp[MAX_PATH];
  DA_CHECK(GetTempPathW(MAX_PATH, temp));
  const auto path = std::wstring(temp) + L"vg2-workspace-" +
                    std::to_wstring(GetCurrentProcessId());
  const auto marker = path + L"\\devagents-engine.exe";
  DA_CHECK(CreateDirectoryW(path.c_str(), nullptr));
  WriteFixture(marker, "");
  {
    beats::DocumentManager manager;
    std::string error;
    int activations = 0;
    const auto activate = [&activations](const std::wstring &, std::string &) {
      ++activations;
      return true;
    };
    DA_CHECK(!manager.AuthorizeWorkspaceRoot(path, error, activate));
    DA_CHECK(error.find("E_WORKSPACE_INSTALLATION") == 0);
    DA_CHECK(activations == 0 && manager.ActiveWorkspaceRoot().empty());
    DA_CHECK(!manager.IsWorkspacePath(path));
    DA_CHECK(DeleteFileW(marker.c_str()));
    DA_CHECK(!manager.AuthorizeWorkspaceRoot(
        path, error,
        [](const std::wstring &, std::string &) { return false; }));
    DA_CHECK(!manager.IsWorkspacePath(path) &&
             manager.ActiveWorkspaceRoot().empty());
    DA_CHECK(manager.AuthorizeWorkspaceRoot(path, error, activate));
    DA_CHECK(manager.IsAuthorizedWorkspaceRoot(path));
    DA_CHECK(!manager.ActiveWorkspaceRoot().empty() && activations == 1);
  }
  DA_CHECK(RemoveDirectoryW(path.c_str()));
  std::cout << "[PASS] VG2 workspace activation rejects installation and rolls "
               "back on engine rejection\n";
}

int main(int argc, char **argv) {
  test_vg2_workspace_activation();
  if (argc == 2 && std::string(argv[1]) == "--seg011-h7") {
    test_seg011_h7();
    return 0;
  }
  if (argc == 2 && std::string(argv[1]) == "--seg011-h3-manager") {
    test_seg011_h3();
    return 0;
  }
  if (argc == 2 && std::string(argv[1]) == "--seg011-h3") {
    test_seg011_h3_atomic();
    test_seg011_h3();
    return 0;
  }
  if (argc == 2 && std::string(argv[1]) == "--seg011-h4") {
    test_seg011_h4();
    return 0;
  }
  if (argc == 2 && std::string(argv[1]) == "--seg011-h3-atomic") {
    test_seg011_h3_atomic();
    return 0;
  }
  test_seg011_h3_atomic();
  test_seg011_h4();
  test_seg011_h7();
  test_seg011_h3();
  // Una ruta enviada por JS no concede permiso de escritura por sí sola.
  {
    wchar_t temp[MAX_PATH];
    DA_CHECK(GetTempPathW(MAX_PATH, temp));
    std::wstring path = std::wstring(temp) + L"beats_doc_security_denied_" +
                        std::to_wstring(GetCurrentProcessId()) + L".txt";
    beats::DocumentManager manager;
    std::string error;
    const bool saved = manager.SaveDocument(path, "untrusted", true, error);
    DeleteFileW(path.c_str());
    DA_CHECK(!saved);
    std::cout << "[PASS] No implicit write authority\n";
  }
  test_document_open_save_conflict();
  test_document_bom();
  test_document_large_and_binary();
  test_confined_save();
  test_atomic_save();
  test_session_retention_allows_siblings_not_components();
  test_protected_write_zones();
  test_broad_startup_roots_are_not_granted();
  test_unc_path_policy();
  test_win32_device_names_denied_everywhere();
  std::cout << "ALL DOCUMENT MANAGER TESTS PASSED!\n";
  return 0;
}
