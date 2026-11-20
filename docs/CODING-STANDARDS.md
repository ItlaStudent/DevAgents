# DevAgents — Estándares de Programación (OBLIGATORIOS)

**Carácter**: vinculante por el Principio VIII de la constitución. Aplica a TODO código del proyecto, lo escriba un humano, un agente free-tier o un modelo de pago. El departamento de Auditoría rechaza cualquier entrega que los incumpla; el rechazo se registra en el ledger.
**Última actualización**: 2026-06-18

## 1. Reglas universales (los tres lenguajes)

1. **Todo error se maneja o se propaga explícitamente.** Prohibido ignorar códigos de retorno, capturar excepciones vacías o usar `catch(...)`/`_ = err` sin justificación comentada.
2. **Sin números/cadenas mágicas**: constantes con nombre y unidad (`TIMEOUT_CONNECT_MS`, no `5000`).
3. **Funciones cortas y de propósito único**: ≤ 60 líneas como regla; superar el límite exige justificación en la revisión.
4. **Nombres autoexplicativos** en inglés para código; comentarios solo para explicar *por qué* (restricciones, invariantes), nunca *qué* hace la línea.
5. **Toda función pública lleva test.** Test no ejecutado = test fallido. La cobertura de ramas de error es obligatoria, no opcional.
6. **Sin estado global mutable** salvo registro justificado en ADR. Inyección de dependencias por parámetro/estructura de contexto.
7. **Concurrencia disciplinada**: todo dato compartido entre hilos/procesos tiene propietario documentado y primitiva de sincronización explícita; prohibido el acceso "benigno" sin lock.
8. **Entradas externas son hostiles**: todo lo que llega de red, FS, usuario, LLM o plugin se valida antes de usarse (longitud, rango, encoding, esquema JSON).
9. **Sin TODO sin ticket**: cada `TODO`/`FIXME` referencia un ítem del checklist o una feature spec; los huérfanos bloquean la auditoría.
10. **Commits atómicos** por tarea de `tasks.md`, mensaje en imperativo, referencia al ID de tarea (`T-F2-03: add Groq connector`).
11. **Formato automático innegociable**: `zig fmt` / `clang-format` (config del repo) en hook pre-commit; el CI rechaza código sin formatear.
12. **Compilación limpia**: cero warnings con los flags del repo. Un warning nuevo = build rojo.

## 2. Zig (núcleo, orquestación, conectores)

- Errores con `error sets` explícitos y `try`/`errdefer`; prohibido `catch unreachable` fuera de invariantes demostradas (comentadas).
- Asignadores SIEMPRE inyectados (`std.mem.Allocator` por parámetro); en tests, `std.testing.allocator` para detectar fugas — un leak es un fallo de test.
- `defer`/`errdefer` inmediatamente después de cada adquisición de recurso.
- Sin `@ptrCast`/`@alignCast` salvo en la frontera ABI, aislados en módulos `ffi_*.zig`.
- Structs de configuración con defaults explícitos; nada de parámetros booleanos posicionales.

## 3. C (ABI de plugins, interoperabilidad)

- Estándar **C11**. Flags mínimos: `-Wall -Wextra -Werror`, builds de desarrollo con ASan/UBSan.
- Toda función de la ABI: prefijo `da_`, retorna código de error tipado (`da_result_t`), out-params al final, `const` correcto.
- Propiedad de memoria documentada en el header de cada función (quién asigna, quién libera); pares `da_x_create`/`da_x_destroy` simétricos.
- Prohibidos: `strcpy`, `sprintf`, `atoi`, `gets` — usar variantes con límite (`snprintf`, `strtol`).
- Structs de la ABI versionados (`size`+`version` como primer campo) para compatibilidad binaria de plugins.

## 4. C++ (IDE/Qt)

- Estándar **C++20**. Mismos flags estrictos que C + `clang-tidy` con el perfil del repo.
- **RAII total**: prohibido `new`/`delete` desnudos; `std::unique_ptr` por defecto, `std::shared_ptr` solo con justificación; en jerarquías Qt, parent-ownership documentado.
- Reglas Qt: señales/slots con sintaxis de punteros a función (no `SIGNAL()`/`SLOT()` por cadena); nada de trabajo bloqueante en el hilo de UI — todo I/O o cómputo va a workers; comunicación entre hilos solo por señales con `QueuedConnection`.
- `override` y `final` explícitos; `explicit` en constructores de un argumento; sin excepciones cruzando la frontera con la API C del núcleo.
- El wrapper de Scintilla es el ÚNICO módulo que toca su API; el resto del IDE consume la interfaz propia (`IEditorView`).

## 5. Frontera entre lenguajes

- Todo cruce C++↔Zig pasa por `devagents_core.h` (API C pura): sin tipos C++/Zig en la frontera, solo tipos C planos, handles opacos y callbacks con `void* user_data`.
- Las cadenas cruzan como `(ptr, len)` UTF-8, jamás dependiendo de `\0` implícito.
- Cada función de la frontera tiene un test de ida y vuelta en `tests/abi/`.

## 6. TypeScript / WebUI (cabina nativa del IDE)

La capa de WebUI se ejecuta en WebView2 nativo sobre el host C++ (ver [ADR-B002](adr/ADR-B002-cabina-nativa-webview2.md)). Es un **cliente delgado**: no contiene lógica de orquestación (planificación, routing, ejecución y auditoría viven 100% en el motor nativo). El gate de calidad es equivalente al de los lenguajes nativos:

1. **`tsc --noEmit` con cero errores** — equivale a "cero warnings" del lado nativo. Un error de tipos es un build roto.
2. **ESLint limpio** — cero errores, cero warnings. Reglas de tipo `@typescript-eslint` activadas.
3. **Tests unitarios** — `vitest` como runner; toda función pública o componente lleva test. La cobertura de ramas de error es obligatoria. **Un test que no corrió es un test que falló** (Principio V, aplica igual).
4. **Tests de integración E2E** — pruebas de integración sobre WebView2 mediante automatización CDP (`tests/live/`).
5. **Formato Prettier** — `prettier --check` en pre-commit; el CI rechaza código sin formatear.
6. **Sin lógica de orquestación en la UI** — la UI observa y presenta; planificación, routing, ejecución y auditoría viven en el motor. Violación de esta regla = rechazo de auditoría.

## 7. Aplicación a los agentes (cómo se hace cumplir)

1. El prompt de sistema de todo agente de Programación incluye la sección relevante de este documento.
2. El departamento de Testing ejecuta formato + warnings + tests + sanitizers como gate automático ANTES de pasar a Auditoría.
3. El departamento de Auditoría verifica el cumplimiento punto por punto con un modelo DISTINTO al constructor y registra el veredicto en el ledger (ver CHECKLIST.md).
4. Una violación justificable (p. ej. función >60 líneas inevitable) se documenta en la entrega y la acepta o rechaza el auditor — nunca el propio constructor.
