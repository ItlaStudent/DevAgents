> HISTÓRICO — evidencia del lote 4 y decisiones del 2026-10-05. No declara el cierre de seguridad del lote 5; el estado vigente está en la documentación interna y la documentación interna

# Lote 4 — confinamiento de mutaciones

Estado: corrección del TOCTOU por symlink/junction implementada y probada; **no es cierre total de seguridad**. La carrera de hardlinks queda como riesgo residual aceptado hasta el lote 5 por decisión del propietario delegada al coordinador (5-oct-2026), con el alcance y los controles descritos abajo. Las fronteras de procesos externos siguen pendientes. Sin commits, cambios en `.git`, datos del propietario ni modificaciones de `executor.zig`/`executeRunCommand`.

## Archivos y decisiones

| Archivo (`core/src/`) | Cambio |
|---|---|
| `confined_fs.zig` | `Root.initMutation`, `Mutation`, creación, copia, borrado y limpieza recursiva por handles. |
| `governed_tool_executor.zig` | `write_file` y `edit_file` usan la raíz retenida; edición lee/escribe el mismo archivo. Mantiene errores JSON y cotas. |
| `workspace.zig` | Persistencia y bloques de edición/parches; raíz compartida por lote, hooks antes de abrir y después de cerrar el archivo. |
| `acp_client.zig` | `fs/write_text_file` confinado, conserva `FsDenied`/`FsError` y límites. |
| `worktree_prepare.zig` | Copia desde handle validado; creación exclusiva del destino y padres seguros. Conserva omisión de existentes/ausentes. |
| `best_of_n.zig` | Aplicación del ganador: copias y borrados confinados; crea el destino si falta. |
| `spaces.zig` | Creación de padres y espacio no-Git mediante `Root`; Git conserva su contrato. |
| `superagent.zig` | Guard exclusivo retenido hasta terminar Node y eliminado sobre su mismo handle; cwd creado y validado por `confined_fs`, ancestros retenidos durante la ejecución. |
| `browser_gate.zig` | Copias, driver y borrado de perfil confinado; fallos ya no se ocultan. Lectura del log por handle validado. |

`NtCreateFile` recibe un solo componente relativo al handle del padre, `FILE_OPEN_REPARSE_POINT` y `OBJ_DONT_REPARSE`. `OPEN_IF` permite crear sin truncar un objeto todavía no validado. Atributos, nombre canónico, identidad y `NumberOfLinks == 1` se comprueban sobre el handle devuelto antes de truncar con `SetEndOfFile` y escribir; no se usa `CREATE_ALWAYS` ni `TRUNCATE_EXISTING`. `WriteFile`/`SetEndOfFile` y `FileDispositionInfo` operan sobre él. Véase el [contrato de NtCreateFile](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-ntcreatefile).

Los ancestros permanecen abiertos sin compartir escritura/borrado hasta terminar. Solicitan `FILE_TRAVERSE`: `READ_ATTRIBUTES` solo **no participa suficientemente en los controles de compartición para impedir renombres**, detectado por la regresión de raíces recién creadas. No se exige listar los ancestros. La escritura completa no exige leer el destino; la edición sí. `createRoot` transfiere los handles nuevos, sin reabrir la raíz por nombre.

Se rechazan ADS, dispositivos, componentes ambiguos, traversal, reparse points y alias canónicos 8.3. Se conservan rutas absolutas con `/`, Unicode y rutas ordinarias de más de 260 caracteres. El prefijo de entrada `\\?\` sigue rechazado como en el escritor anterior; internamente se utiliza el espacio extendido para abrir raíces largas.

Las raíces se reutilizan en operaciones por lote; el coste depende de la profundidad, sin recorrer el árbol para cada escritura. La copia usa un buffer de 64 KiB. No se añadió dependencia ni caché global. No se midió un benchmark de árboles grandes.

## Pruebas y evidencia

Desde la raíz del worktree, con el Zig indicado por el propietario:

```powershell
& .\tools\suite_evidence.ps1 -Mode sec-fs-focused -Topic sec-fs-focused
& .\tools\suite_evidence.ps1 -Mode sec-fs -Topic sec-fs-regression
python tools/sec_fs_hardlink_probe.py
```

El script comprueba C: antes de cada compilación: mínimo **20 GB** (20 GiB en PowerShell; `MinFreeGB` nunca inferior a 20). Los modos SEC-FS usan una caché nueva por invocación en `%LOCALAPPDATA%\Temp\beats-cache-sec-fs-<GUID>`, con global/prefijo/TMP propios. Registran el comando completo y usan el fixture aislado existente. `sec-fs` selecciona todos los tests declarados en `confined_fs`, `governed_tool_executor` y `superagent`, incluidos los de comandos; no es la suite global. Un `SKIP` conserva el gate en error. El probe es diagnóstico y está fuera de ambos modos. Los wrappers `sec_fs_evidence.ps1` y `sec_fs_cleanup.ps1` se eliminaron.

### Ronda 2 (5-oct-2026)

- Control negativo del guard: implementación anterior con la nueva prueba, 1 aprobada y 1 fallida; código corregido restaurado en `finally`. Node podía eliminar el guard anterior.
- Filtro SEC-FS, repetición del mismo binario: **17 aprobadas, 1 SKIP, 0 fallos**, proceso exit 0 y gate 1. Incluye hardlink exterior preexistente sin cambios de bytes, cwd creado/confinado con padres retenidos, guard protegido durante Node y eliminado al terminar. El primer intento tuvo 16 fallos dominados por `AccessDenied` abriendo ancestros; no se modificó código ni se debilitaron controles para repetir. Causa transitoria no confirmada.
- Regresión final de los tres módulos: **248 aprobadas, 1 SKIP, 0 fallos**; proceso exit 0 y gate 1. El SKIP de symlink de archivo se debe exactamente a **`ERROR_PRIVILEGE_NOT_HELD (1314)`**, no a un PASS ni a un fallo de aserción. El intento anterior dio 247/1/1: faltaba `cli-worker-mock.exe`; el modo SEC-FS ahora construye ese fixture existente antes de los tests. E2E SNAP y los tres casos Node QA-V1 pasan en la ejecución final.
- Formato final: `zig fmt --check` sobre los nueve Zig, exit 0; sintaxis PowerShell sin errores y las tres eliminaciones comprobadas.
- Se esperó a disponer de 20 GiB antes de compilar. La ejecución final registró 21.772.349.440 bytes antes del mock y 21.728.575.488 antes de compilar tests, ambos superiores a 20 GiB. Limpieza de cachés generadas por esta sesión; no se borraron cachés ajenas/preexistentes.

Sin suite global ni cabina en esta ronda. El probe conserva su carácter diagnóstico, fuera de la suite verde; el riesgo residual y el aislamiento pendiente no se convierten en `AUDIT PASS`.

### Evidencia histórica (4-oct-2026)

- Control negativo: se transplantó únicamente el nuevo test de junction interna a `governed_tool_executor.zig` de `HEAD`, se ejecutó el filtro y se restauró el archivo en `finally`. Resultado esperado: 1 prueba funcional fallida más el test de importación aprobado. Salida roja.
- Mismo filtro corregido: **20/20 pasos, 2/2 pruebas, exit 0**. Salida final.
- Regresión enfocada: **169 aprobadas, 1 omitida, 0 fallos funcionales**; el script devuelve **1** por la omisión. Salida completa, con comando exacto.
- La omitida es `SEC-FS file symlink never truncates its external target`: `CreateSymbolicLinkW` devuelve `ERROR_PRIVILEGE_NOT_HELD (1314)`. No se cambiaron privilegios ni configuración del sistema.
- Pasan la carrera determinista que sustituye un directorio por junction antes de abrirlo (sentinela exterior intacta, ningún fichero/directorio exterior nuevo), junction interna/externa, alias 8.3 real, ADS, dispositivos, Unicode, rutas largas, truncado, bloqueo de padres, borrados y copias. Pasan también los tres tests E2E existentes de navegador real del gate. No se reconstruyó ni probó la cabina/WebUI.
- `zig fmt` aplicado a los ocho archivos Zig. No hubo cambios C++; `clang-format` no aplica.
- Formato y comprobación de las zonas excluidas: exit 0; `executor.zig`, `executeRunCommand` y `executeAgenticTool` sin cambios.
- Limpieza histórica mediante el wrapper ahora eliminado: caché propia eliminada (853.957.239 bytes), junto con los mocks del primer build. Salida de limpieza, `CACHE_REMAINS=False`, exit 0.

Los primeros intentos fallaron por temporales MinGW en `%TEMP%` y luego por defectos de implementación/fixtures; se conservan los logs. Usar `TMP`/`TEMP` dentro de la caché propia resolvió el bloqueo de compilación. No se presentan esos intentos como pruebas aprobadas.

## Riesgo confirmado: hardlink añadido durante la escritura

`rejectHardLinks` rechaza enlaces **ya presentes** y vuelve a comprobar antes de modificar. No puede hacer atómico el intervalo entre comprobar y escribir. El [contrato de FILE_LINK_INFORMATION](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_link_information) no exige derechos específicos para la operación.

`tools/sec_fs_hardlink_probe.py` reproduce, con archivos temporales y los mismos derechos/compartición del escritor, que tanto `CreateHardLinkW` como `NtSetInformationFile(FileLinkInformation)` mediante un handle de metadata añaden alias exteriores mientras el handle escritor sigue abierto. La escritura posterior se ve en ambos alias. Evidencia: 40 bytes visibles fuera y fixture eliminado. **Exit 0 del probe significa reproducción terminada, no seguridad PASS.**

Decisión del 5-oct-2026: el propietario delegó «lo mejor para DevAgents» al coordinador, que aceptó temporalmente este riesgo hasta el lote 5. No se afirma confinamiento absoluto de bytes observables fuera.

Razonamiento revisado: un hardlink nuevo publica otro nombre del mismo objeto, no redirige un handle ya abierto a un archivo diferente ([semántica NTFS](https://learn.microsoft.com/en-us/windows/win32/fileio/hard-links-and-junctions)). Después de comprobar que el objeto abierto dentro del workspace sólo tiene un enlace, crear un alias exterior de ese objeto no concede escritura sobre otro archivo preexistente que el atacante no controlaba. La publicación necesita autorización efectiva en el directorio destino. Sustituir un nombre existente requiere los permisos de sustitución correspondientes; no cambia el objeto referido por el handle escritor. No se encontró un contraejemplo concreto dentro de este supuesto. Esto no afirma que crear una entrada equivalga a poder escribir cualquier archivo de ese directorio, ni cubre lectores externos que decidan confiar en ese nuevo nombre.

Un alias de un archivo exterior introducido **antes** de abrir/comprobar el destino conserva múltiples enlaces y se rechaza antes de truncar; la prueba determinista exige sentinela exterior idéntica tras intentos de escritura, edición y copia. Retener identidad y ancestros impide cambiar el objeto escrito mediante sustitución de rutas. `NumberOfLinks` sigue sin ser un bloqueo atómico frente a publicación posterior.

El lote 5 debe implementar el token restringido para los procesos hijos del modelo de modo que impida crear enlaces en directorios ajenos: SIDs restrictivos y permisos efectivos limitados a los destinos autorizados, sin handles heredados que evadan el control. [Windows comprueba ambos conjuntos de SIDs](https://learn.microsoft.com/en-us/windows/win32/secauthz/restricted-tokens); quitar privilegios o llamar a `CreateRestrictedToken` sin una política efectiva no acredita ese aislamiento. Pendiente comprobar ambos caminos del probe con ese token. El control no está implementado en el lote 4 y no limita a procesos independientes que sigan ejecutándose con el token completo del propietario.

## Inventario de fronteras no migradas

| Ruta | Motivo y riesgo pendiente |
|---|---|
| `spaces` y `ship_flow` | `git worktree add/remove/prune`, checkout, add/commit y otros efectos se ejecutan en Git. Cambiar la llamada por un handle no cambia cómo Git resuelve nombres. Requiere confinar el proceso; no se implementó renombre nativo adicional porque no existe ese camino gobernado en el inventario. |
| Hooks de `workspace`, setup de `worktree_prepare`, ejecución de comandos | Los procesos externos reabren sus rutas. El archivo propio del motor se cierra antes de los formatters. Preservar la autorización y el protocolo de esos procesos corresponde a los otros lotes. |
| Chromium en `browser_gate` | Preparación y limpieza del motor migradas. Escritura del perfil y log hecha por Chromium permanece en el proceso externo y no hereda la garantía de `Mutation`. |
| Snapshots de `headless_adapter` | Captura de lectura ya usa `Root`; no se encontró restauración nativa de archivos por snapshot. Aplicar bloques de edición pasa por `workspace` y aplicar un ganador por `best_of_n`, ambos migrados. |
| `best_of_n.walkArtifactDir` | Enumeración aún por nombre; apertura del contenido y toda mutación posterior son confinadas. No se atribuye a este cambio protección total de la enumeración frente a cambios concurrentes. |
| `cli.cmdDesign`, capturas/token de `c_api`, logs/configuración interna, adjuntos | Son salidas explícitas o almacenamiento interno, no la secuencia de validación/escritura gobernada del worktree. Adjuntos ya tiene su propio esquema relativo/no-follow. No se migraron ni se certificaron en este lote. |

Riesgos de regresión: rechazo deliberado de alias/hardlinks preexistentes, conflictos de compartición con otros escritores, permisos de traverse en ancestros y errores ahora explícitos al aplicar un ganador/gate. La regresión enfocada cubre sus flujos habituales; faltan cabina integrada, suite completa y symlink con privilegio. Las auditorías locales `.codex-auditoria-seguridad.md` y `.codex-auditoria-lote4.md` permanecen sin versionar. `PROYECTO_RESUMEN.md` se eliminó conforme al handoff.

Sin commit en esta sesión. Mensaje de commit propuesto para integración posterior: `Core (confinamiento): mutaciones gobernadas por handles sin reabrir rutas`.
