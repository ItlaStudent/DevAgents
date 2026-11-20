#include "hunk_manager.hpp"
#include "document_manager.hpp"

#include <cstddef>

namespace beats {
namespace {

std::vector<std::string> SplitLines(const std::string &text) {
  std::vector<std::string> lines;
  if (text.empty())
    return lines;
  std::size_t begin = 0;
  for (;;) {
    const std::size_t pos = text.find('\n', begin);
    if (pos == std::string::npos) {
      lines.push_back(text.substr(begin));
      break;
    }
    lines.push_back(text.substr(begin, pos - begin));
    begin = pos + 1;
    if (begin == text.size()) {
      lines.push_back(std::string());
      break;
    }
  }
  return lines;
}

std::string JoinLines(const std::vector<std::string> &lines) {
  std::string out;
  for (std::size_t i = 0; i < lines.size(); ++i) {
    if (i)
      out.push_back('\n');
    out += lines[i];
  }
  return out;
}

bool SameLines(const std::vector<std::string> &a,
               const std::vector<std::string> &b, std::size_t start,
               std::size_t count) {
  if (a.size() != count || start > b.size() || b.size() - start < count)
    return false;
  for (std::size_t i = 0; i < count; ++i) {
    if (a[i] != b[start + i])
      return false;
  }
  return true;
}

const Hunk *FindHunk(const std::vector<Hunk> &hunks, int hunkId) {
  for (const auto &hunk : hunks) {
    if (hunk.id == hunkId)
      return &hunk;
  }
  return nullptr;
}

bool ReadCurrent(const DocumentManager &documents, const std::wstring &path,
                 std::vector<std::string> &lines) {
  std::string current;
  if (!documents.ReadWorkspaceFile(path, current))
    current.clear();
  lines = SplitLines(current);
  return true;
}

// P1b (r3) + r4: antes de reinsertar las lineas de un hunk de solo borrado
// aceptado, comprueba el contexto que resta a su alrededor comparando el
// archivo actual con el contenido base pre-dif que trajo el llamador: la linea
// anterior al punto de reinsercion y la primera linea que quedo despues del
// rango borrado. r4 lo hace estricto: el base debe ser el original completo
// del diff para poder indexarlo con la posicion del archivo; si el dato no
// esta (base vacio o demasiado corto) no hay forma de verificar el contexto y
// se falla SIN escribir, nunca se reinserta a ciegas. Un borrado de todo el
// archivo no deja vecinos: solo se acepta si el base es exactamente el rango
// borrado y el archivo actual quedo vacio.
bool ReinsertionContextValid(const std::vector<std::string> &baseLines,
                             const std::vector<std::string> &lines,
                             std::size_t start, std::size_t originalCount,
                             std::string *outError) {
  const auto fail = [&] {
    if (outError)
      *outError = "El archivo cambió alrededor del hunk; no se rechazó";
    return false;
  };
  bool checked = false;
  if (start > 0) {
    if (start - 1 >= baseLines.size() || start - 1 >= lines.size() ||
        baseLines[start - 1] != lines[start - 1])
      return fail();
    checked = true;
  }
  if (start < lines.size()) {
    if (start + originalCount >= baseLines.size() ||
        baseLines[start + originalCount] != lines[start])
      return fail();
    checked = true;
  }
  if (!checked &&
      !(start == 0 && lines.empty() && baseLines.size() == originalCount))
    return fail();
  return true;
}

bool ApplyRange(const Hunk &hunk, const std::string &baseFileContent,
                std::vector<std::string> &lines, bool reject,
                std::string &outNewFileContent, std::string *outError) {
  const std::vector<std::string> original = SplitLines(hunk.originalContent);
  const std::vector<std::string> replacement = SplitLines(hunk.newContent);
  const std::size_t start = static_cast<std::size_t>(hunk.startLine - 1);
  const std::size_t originalCount =
      static_cast<std::size_t>(hunk.originalLineCount);
  const std::size_t newCount = static_cast<std::size_t>(hunk.newLineCount);

  if (hunk.originalLineCount < 0 || hunk.newLineCount < 0 ||
      original.size() != originalCount || replacement.size() != newCount) {
    if (outError)
      *outError = "El rango del hunk no coincide con su contenido";
    return false;
  }
  // P1a (r3): el limite valido en comun es la posicion de insercion/borrado
  // (start puede caer justo al final del archivo, posicion == numero de
  // lineas). El conteo del rango se valida en cada rama segun el estado que
  // se revisa:
  // * accept o rechazo del estado original: deben existir originalCount lineas.
  // * reversion del estado aceptado: deben existir las newCount lineas que el
  //   hunk dejo, que pueden ser cero (solo borrado) y entonces solo exige la
  //   posicion de reinsercion de arriba.
  if (start > lines.size()) {
    if (outError)
      *outError = "El rango del hunk queda fuera del archivo actual";
    return false;
  }

  if (reject) {
    // El estado que se revierte es el ACEPTADO: el rango debe contener las
    // newCount lineas del hunk, se borran exactamente esas y se restauran las
    // originalCount originales. Si el rango ya esta en original no hay nada
    // que rechazar. Un hunk de solo borrado (newCount == 0) no deja lineas
    // propias que comparar: si las originales no estan, el aceptado las quito
    // y el rechazo las reinserta; uno de solo insercion (originalCount == 0)
    // no puede distinguir "ya rechazado" de "archivo cambiado", asi que si el
    // reemplazo no esta se trata como archivo cambiado.
    if (newCount > 0 && SameLines(replacement, lines, start, newCount)) {
      lines.erase(lines.begin() + static_cast<std::ptrdiff_t>(start),
                  lines.begin() +
                      static_cast<std::ptrdiff_t>(start + newCount));
      lines.insert(lines.begin() + static_cast<std::ptrdiff_t>(start),
                   original.begin(), original.end());
    } else if (originalCount > 0 &&
               SameLines(original, lines, start, originalCount)) {
      // Ya rechazado o nunca aplicado: el archivo conserva el original.
    } else if (newCount == 0 && originalCount > 0) {
      // P1b (r3): reinsercion de un hunk de solo borrado aceptado, solo
      // despues de verificar el contexto alrededor del punto de insercion.
      const std::vector<std::string> baseLines = SplitLines(baseFileContent);
      if (!ReinsertionContextValid(baseLines, lines, start, originalCount,
                                   outError))
        return false;
      lines.insert(lines.begin() + static_cast<std::ptrdiff_t>(start),
                   original.begin(), original.end());
    } else {
      if (outError)
        *outError = "El archivo cambió desde el diff; no se rechazó el hunk";
      return false;
    }
  } else {
    if (start + originalCount > lines.size() ||
        !SameLines(original, lines, start, originalCount)) {
      if (outError)
        *outError = "El archivo cambió desde el diff; no se aplicó el hunk";
      return false;
    }
    lines.erase(lines.begin() + static_cast<std::ptrdiff_t>(start),
                lines.begin() +
                    static_cast<std::ptrdiff_t>(start + originalCount));
    lines.insert(lines.begin() + static_cast<std::ptrdiff_t>(start),
                 replacement.begin(), replacement.end());
  }

  outNewFileContent = JoinLines(lines);
  return true;
}

} // namespace

HunkManager::HunkManager(DocumentManager &documents) : m_documents(documents) {}

HunkManager::~HunkManager() {}

bool HunkManager::AcceptHunk(const std::wstring &path, int hunkId,
                             const std::string &originalFileContent,
                             const std::vector<Hunk> &hunks,
                             std::string &outNewFileContent,
                             std::string *outError) {
  const Hunk *hunk = FindHunk(hunks, hunkId);
  if (!hunk) {
    outNewFileContent = originalFileContent;
    if (outError)
      *outError = "Hunk inexistente";
    return false;
  }

  if (hunk->startLine <= 0) {
    outNewFileContent = originalFileContent;
    std::string error;
    if (!m_documents.WriteWorkspaceFile(path, hunk->newContent, error)) {
      if (outError)
        *outError = error;
      return false;
    }
    outNewFileContent = hunk->newContent;
    return true;
  }

  std::vector<std::string> lines;
  ReadCurrent(m_documents, path, lines);
  const std::string before = JoinLines(lines);
  if (!ApplyRange(*hunk, originalFileContent, lines, false, outNewFileContent,
                  outError)) {
    outNewFileContent = before;
    return false;
  }
  if (outNewFileContent == before)
    return true;
  std::string error;
  if (!m_documents.WriteWorkspaceFile(path, outNewFileContent, error)) {
    outNewFileContent = before;
    if (outError)
      *outError = error;
    return false;
  }
  return true;
}

bool HunkManager::RejectHunk(const std::wstring &path, int hunkId,
                             const std::string &originalFileContent,
                             const std::vector<Hunk> &hunks,
                             std::string &outNewFileContent,
                             std::string *outError) {
  const Hunk *hunk = FindHunk(hunks, hunkId);
  if (!hunk) {
    outNewFileContent = originalFileContent;
    if (outError)
      *outError = "Hunk inexistente";
    return false;
  }

  if (hunk->startLine <= 0) {
    outNewFileContent = originalFileContent;
    std::string error;
    if (!m_documents.WriteWorkspaceFile(path, hunk->originalContent, error)) {
      if (outError)
        *outError = error;
      return false;
    }
    outNewFileContent = hunk->originalContent;
    return true;
  }

  std::vector<std::string> lines;
  ReadCurrent(m_documents, path, lines);
  const std::string before = JoinLines(lines);
  if (!ApplyRange(*hunk, originalFileContent, lines, true, outNewFileContent,
                  outError)) {
    outNewFileContent = before;
    return false;
  }
  if (outNewFileContent == before)
    return true;
  std::string error;
  if (!m_documents.WriteWorkspaceFile(path, outNewFileContent, error)) {
    outNewFileContent = before;
    if (outError)
      *outError = error;
    return false;
  }
  return true;
}

} // namespace beats
