/** Only user additions become instructions; the engine fetches and quotes the issue again. */
export function issueInstruction(text: string, importedPrompt: string): string {
  const position = text.indexOf(importedPrompt);
  if (!importedPrompt || position < 0 || text.indexOf(importedPrompt, position + importedPrompt.length) >= 0) {
    throw new Error('El bloque de incidencia fue modificado. Reimporta la incidencia y escribe tu instrucción antes o después del bloque.');
  }
  return (text.slice(0, position) + text.slice(position + importedPrompt.length)).trim();
}
