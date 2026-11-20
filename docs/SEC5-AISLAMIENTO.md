# SEC5 — Aislamiento de SO, diseño v2

Fecha: 2026-10-09. Constructor: Sol. Worktree: `sec-os`, rama `e5-sec-os`.

**Estado P1 ronda 4: ambos ejecutables compilan; roundtrip semántico y mutación discriminante ejecutados dentro del sandbox. Viabilidad NO VERIFICADA.** §6 contiene la decisión nueva y las mediciones del coordinador; §11.5 recoge la corrida provisional del constructor y sus bloqueos posteriores. Las mediciones que acreditan viabilidad corresponden al coordinador fuera del sandbox. Las matrices siguientes conservan sus criterios; ningún caso adquiere PASS por tener código escrito.

Este documento sustituye al diseño v1 como propuesta técnica autocontenida. No sustituye el veredicto independiente FAIL ni declara cerrados los hallazgos del segundo auditor. Resuelve por escrito sus siete obligatorios; la comprobación empírica y la nueva auditoría quedan pendientes.

Fuentes de decisiones del lote:

- Diseño v1.
- Auditoría independiente del segundo auditor, FAIL.
- Decisiones vinculantes del propietario.

## 1. Alcance de cierre de H3 y riesgo aceptado

### 1.1 Categorías y autoridad

| Categoría | Autoridad y alcance | Tratamiento previsto |
|---|---|---|
| S | Código del modelo, scripts no humanos, repositorios, hooks, verificadores, MCP/LSP de terceros y terminal automática | Token restringido de integridad baja, SID por lease, destinos enumerados, handles explícitos y Job. Aprobar una tarjeta conserva S. |
| E | Exclusivamente Codex, Claude Code y OpenCode por ACP, con permiso emitido por el motor y cadena ejecutable verificada | Excepción persistente; **no reciben el token de DevAgents**. Conservan los permisos de su contexto externo. Job y coordinación de permisos del producto cuando sean aplicables; no equivalen a aislamiento S. |
| H | Acción manual humana autenticada por la cabina | Excepción manual explícita; nunca se infiere por el nombre del shell ni por un texto que reclame ser humano. |
| T | Infraestructura propia fijada que no ejecuta contenido del modelo | Autoridad tipada del producto; no sirve de lanzador arbitrario. Su migración general va después del núcleo S. |
| D | Delegación tipada a Explorer, navegador del sistema o WebView2 confiable | Sin promesa de token S. No se ofrece como escape automático de S. |
| F | Fixtures construidos exclusivamente por las pruebas | No distribuibles como permisos de producción ni excepciones reutilizables por clientes. |

La cabina debe mostrar literalmente **«CLI externo sin aislamiento de DevAgents»** para E. El registro incluye nombre del perfil, ejecutable y cadena shim/entrypoint por identidad/hash, permiso, superficie, orden, destinos declarados, PID/hora de creación, inicio, fin y restauración. Si no puede persistirse la excepción, no se lanza. No se guardan credenciales, entorno completo ni prompts.

Ningún otro CLI, servidor MCP o proceso recibe E por compartir un transporte o basename. El permiso E autoriza la cadena registrada, no un comando arbitrario suministrado por un cliente. Las aprobaciones S no emiten permisos E. Las ejecuciones que el CLI E realice internamente permanecen fuera de la garantía de DevAgents; sus archivos son de origen no humano cuando vuelven al despacho gobernado.

**Riesgo aceptado por el propietario:** E puede escribir fuera de los destinos, ejecutar código con permisos del usuario y delegar a otros procesos o servicios. Registrar el riesgo no lo elimina. La exclusión S/E coordina a los brokers del producto; no encierra un CLI E malicioso ni a otros procesos ordinarios de la misma cuenta.

### 1.2 Promesa acotada y criterios medibles

La futura declaración de cierre será: «H3 cerrado para los despachos S gobernados de DevAgents: autorización de entrada por origen, identidad y hash; escrituras directas limitadas por el SO a destinos preparados; descendientes Win32 ordinarios contenidos. CLIs E, acciones manuales H, aislamiento de UI, confidencialidad de lectura, red y ejecución delegada a servicios externos quedan fuera».

No se declara protección frente a exfiltración ni frente a un servicio medio que actúe como intermediario privilegiado. Si un transporte medido permite inducir modificaciones exteriores, ese flujo no puede anunciarse aislado: se bloquea hasta disponer de un broker que valide capacidades o de otro mecanismo aprobado. Un Job no captura automáticamente procesos creados por un servicio ajeno.

El cierre requiere simultáneamente:

1. Inventario actualizado y **100 % de los sitios S** pasando por el mismo lanzador, incluidos detached y reanudaciones. Ninguna ruta heredada S habilitada como alternativa.
2. Intentos S persistidos con token efectivo bajo/restringido, Job configurado, destinos por identidad y entradas autorizadas. Cero lanzamientos S reanudados con preparación incompleta o sin prueba de autoridad.
3. Cero scripts no humanos/dirty/desconocidos despachados por DevAgents sin autorización de la cabina ligada a identidad y SHA-256. Cambio de identidad o bytes exige nueva tarjeta.
4. Cero raíces simultáneamente bajo S y E; cero restauraciones aprobadas con un árbol vivo o descriptor divergente; cualquier journal ambiguo bloquea la raíz.
5. **100 % de lanzamientos E** con excepción persistente y etiqueta visible; solo los tres perfiles admitidos. Informar por separado los conteos S, E, H, T y D, sin sumar E como ejecución aislada.
6. Pruebas reales y mutaciones discriminantes en usuario estándar, integración cabina→host→motor, suite global y auditoría independiente. Un prototipo verde no cierra H3.

Para apps GUI S, la decisión del propietario conserva temporalmente el escritorio normal y exige **«sin aislamiento de UI»**. Esa fase podrá acreditar restricciones de archivos/procesos, pero no aislamiento integral de UI. Una falla de acceso a la estación o escritorio bloquea la app; no autoriza ampliar las DACL de `WinSta0` ni retirar el SID restrictivo. P1 no lanza GUI.

## 2. Orden de partes y puertas de habilitación

Este orden adelanta procedencia antes del rollout y separa UI del mínimo viable. Los archivos P1 ya están escritos en la continuidad; los de P2–P8 siguen propuestos. Ninguna puerta está acreditada por esta escritura.

| Parte v2 | Contenido y archivos previstos | Puerta de salida; estado actual |
|---|---|---|
| P1 — Viabilidad sin GUI | `core/src/governed_process.zig`, `tests/sec5_child.zig`, fixtures de padre/objetivo/broker y paso independiente `test-sec5-os` en `build.zig` | Token, MIC/SID, filesystem, registro, objetos de sesión, stdio, Job, fallo cerrado y restauración sobre fixtures; cero migraciones. **NO VERIFICADO**. |
| P2 — Leases durables | `sandbox_acl.zig`, `workspace_acl.zig`, `external_cli_security.c`, `confined_fs.zig`, adaptación de `process_tree.zig` | Derechos, identidad, exclusión S/E, journal, herencia, crashes y recuperación entre procesos. No habilitar sobre espacios reales antes de esta puerta. **NO VERIFICADO**. |
| P3 — Procedencia y autorización | `file_provenance.zig`, `command_policy.zig`, `db.zig`, escritores gobernados/ACP/clone/editor, reclamo C-ABI y tarjeta de cabina | Tarjeta por identidad/hash, captura dirty, reclamo único y contrato de entrada retenida de §3. Elimina la exención por archivo local. **NO VERIFICADO**. |
| P4 — Ejecutor S, detached y hooks | `executor.zig`, `hooks.zig`, `superagent.zig`, `governed_tool_executor.zig`, setup/verificación/webhooks y sus reanudaciones | Ningún spawn S de esas rutas fuera del módulo; Job/lease vivos durante todo el árbol. H9 mantiene el guard de verificación Node al reanudar. **NO VERIFICADO**. |
| P5 — Git y providers | `providers/src/github.zig`, `spaces.zig`, `headless_adapter.zig`, `ship_flow.zig` y sus adaptadores | Git S con metadata privada, sin rebajar `.git` compartida; clone/ship y mantenimiento tipado probados. **NO VERIFICADO**. |
| P6 — Transportes y host S/E/H | `mcp_client.zig`, `cli_worker.zig`, `acp_client.zig`, Engram/agentes externos; `bridge.cpp`, `lsp_client`, `pty_manager`, fachada C común | MCP/LSP S, E explícita, sesión manual separada, pipes y ConPTY medidos. El host usa la misma implementación, no una copia de política en C++. **NO VERIFICADO**. |
| P7 — Integración del núcleo y cierre acotado | Inventario, agregados SEC5, contratos versionados, documentación SEC2/SEC-FS y cabina | Cumple §1.2 contra binarios desplegados; auditoría posterior. Los S incompletos permanecen deshabilitados. **NO VERIFICADO**. |
| P8 — Mejoras separables | Escritorio/estación, «Ver aplicación aislada», preview fuera del WebView2 compartido, límites por toolchain, delegaciones D y migración T | Gates propios de UI, infraestructura y compatibilidad; no se atribuyen a P1 ni se usan para retrasar la medición básica. **NO VERIFICADO**. |

P4–P6 pueden construir adaptadores sin activarlos; la activación exige P1, P2 y P3. No es válida una activación temporal con token ordinario ni con la exención de procedencia antigua. Cambios públicos C-ABI/MCP y migraciones se versionan; el número de migración se asigna desde el esquema real al implementar, sin inventarlo en este documento.

## 3. Contrato del lanzador y entrada autorizada

### 3.1 `LaunchRequest`

Contrato interno nuevo, no una estructura existente. Su `Authority` es una unión de permisos opacos emitidos por el motor: `sandbox`, `verified_external_cli`, `human_manual`, `product_service`. P1 implementará únicamente `Authority.sandbox` con fixtures. El permiso no se deserializa de un booleano o categoría que envíe MCP/JavaScript.

| Campo de `LaunchRequest` | Contrato |
|---|---|
| `authority` | Permiso retenido, vigente y ligado a categoría, orden y operación. |
| `executable` | Objeto ejecutable retenido con handle, volumen/FileId, hash, ruta de ejecución comprobada y cadena de shims resuelta. `lpApplicationName` absoluto y explícito. |
| `authorized_input` | Unión explícita `AuthorizedInput`, descrita abajo. Obligatoria: también representa inline y la ausencia comprobada de script. |
| `args` | Vector tipado, escapado por una sola implementación; posiciones de código/archivo vinculadas a `authorized_input`. No cadenas libres que puedan cambiar el entrypoint aprobado. |
| `cwd` | Directorio retenido, identidad y ancestros comprobados; ruta absoluta vinculada al objeto. |
| `environment` | Bloque explícito UTF-16 filtrado; temporales y cachés dentro de los destinos de la lease. |
| `stdio` / `inherited_handles` | Capacidades exactas, dirección y propietario; únicamente handles autorizados, válidos y duplicados con los derechos mínimos. |
| `lifetime` / `limits` | propietario hasta árbol vacío; timeout/cancelación y límites de recursos. Detached no abandona el Job. |
| `launch_id` / `audit_context` | Registro durable del intento y referencia a la autorización; no contienen secretos. |

`AuthorizedInput` tiene variantes `retained_file`, `private_snapshot`, `inline_bytes` y `executable_only`. Las tres primeras contienen un objeto de entrada con estos datos:

- **Handle de lectura retenido**, no heredable; identidad del archivo (`VolumeGuid`, serial del volumen, `FILE_ID_128`), tamaño y SHA-256 calculados por ese handle.
- Identidad de raíz, ruta relativa y generación de procedencia; origen y estado reconciliado/dirty/desconocido.
- ID de autorización consumible una vez, categoría S y hash del contexto efectivo (intérprete, argv, cwd, destinos y estrategia).
- Estrategia: ruta retenida comprobable, copia privada por nombre, bytes inline fijados o stream explícitamente soportado por ese intérprete.
- Handles de ancestros necesarios para impedir sustitución del nombre, binding entre entrada y posición de argv/stdio, y diagnóstico de validación.

`inline_bytes` también posee un respaldo privado retenido del contenido y su hash; el broker construye de él la cadena exacta `-e`/`-c` o el stream. No autoriza otra cadena enviada después. `executable_only` incluye prueba tipada de que no se pasa código por flags/stdio; si hay `-c`, `-e`, `-Command`, `-File`, batch o equivalente, exige una variante con contenido. Un perfil de intérprete no reconocido bloquea el despacho. No hay bypass por «binario confiable» que acepte scripts sin objeto de entrada.

### 3.2 Resolver nombre y bytes sin TOCTOU

El broker no puede entregar un handle como `lpApplicationName`: Windows y el intérprete reabren nombres. Por tanto, un hash correcto seguido de un path libre **no** es suficiente.

1. Al mostrar la tarjeta, leer entrada por handle confinado y registrar identidad/hash. No se mantienen handles bloqueantes durante la espera humana.
2. Al reclamarla, reabrir y revalidar por handles: identidad, bytes, autorización, origen/generación y contexto. Cambio invalida la tarjeta y no ejecuta.
3. Para `retained_file`, abrir archivo sin compartir escritura/borrado y retener cada ancestro relevante contra renombre/reparse; verificar que la ruta exacta que usará el intérprete reabre el mismo FileId en el mismo volumen. Rechazar reparse points, aliases no resolubles y writers incompatibles. La verificación se hace antes del spawn y se conserva la retención hasta árbol vacío.
4. **Límite adicional:** el sharing de handles no demuestra ausencia de una sección escribible mapeada anteriormente. La ruta original solo se admite si su inmutabilidad tiene una cadena de creación/retención controlada por el broker que excluye esa capacidad. Un archivo del workspace expuesto previamente a terceros se ejecuta mediante copia privada; no se promete inmutabilidad por una sola apertura sin `FILE_SHARE_WRITE`.
5. La copia privada se crea con nombre nuevo y `CREATE_NEW` bajo raíz de control media del broker, fuera de destinos S; propietario y DACL explícitos, sin ACE de escritura del SID de lease. Copiar desde el handle autorizado, cerrar el writer del broker, reabrir sin compartir escritura/borrado, comprobar identidad/hash, fijar ancestros y reconstruir el argumento. El proceso S recibe lectura, nunca un handle escribible a la copia. Si la copia no preserva la semántica necesaria (`__file__`, imports relativos, rutas o módulos), exigir snapshot del conjunto o bloquear con motivo; no volver a la ruta mutable.
6. Si no puede acreditarse ninguna estrategia, devolver `AuthorizedInputUnstable` antes de crear/reanudar. No aceptar la mera coincidencia de ruta normalizada.

Las mismas reglas de identidad/ruta se aplican al ejecutable y a cualquier shim/script de su cadena. Los handles y snapshots pertenecen al propietario del árbol, no al frame de `launch`. Al fallar antes de arrancar, se liberan tras terminar/esperar al hijo suspendido; al acabar, después de confirmar árbol vacío. En producción no se libera un pin porque haya terminado solo el proceso principal.

### 3.3 Procedencia y tarjeta por hash

Todo script no humano exige **«Ejecutar archivo de origen no humano»**, incluyendo modelo local, cliente MCP, órdenes `.mcp`, clone/importación, CLI E, proceso hijo y origen desconocido. Solo la cabina resuelve la tarjeta. Su payload muestra identidad, SHA-256, tamaño, origen, intérprete/entrypoint, argv, cwd, destinos, perfil S, detached/verificación y alcance transitivo. El motor reclama atómicamente una sola resolución entre procesos; cliente MCP no puede resolverla ni blanquear el origen.

El registro de origen y autorizaciones vive bajo control medio, fuera del árbol escribible S. Antes de cualquier writer/importación/proceso se persiste `dirty`; después se reconcilian identidad/hash y revisión. Fallo de registro, crash o pérdida de eventos mantiene `dirty`/desconocido. Un watcher es señal, no autoridad. Copiar/renombrar conserva el origen; edición humana registrada conserva la historia. Ausencia de registro no significa humano.

Las escrituras gobernadas, ACP `fs/write_text_file`, setup, clone, aplicación de parches/ganadores y edición humana pasan por este protocolo. Procesos E pueden modificar ubicaciones no observadas; cualquier archivo no conciliado al volver a DevAgents se trata como desconocido. No se inspeccionan claves ni datos reales del propietario para reconciliar pruebas.

**Contenido transitivo:** la tarjeta del archivo principal no aprueba individualmente imports, DLLs, plugins, lifecycle scripts o procesos internos. El permiso explicita ejecución de un conjunto mutable bajo S; si se pretende aprobación por bytes del conjunto, exige snapshot privado con manifiesto de identidades/hashes. Estos mecanismos no interceptan cada import ni cada `CreateProcess` interno. La promesa de H3 corresponde al despacho de DevAgents y a la entrada que representa, con esta frontera declarada.

## 4. Token, handles, Job y fallo cerrado de P1

### 4.1 Precondición de entorno representativo

El padre consulta su propio token antes de preparar fixtures: `IsTokenRestricted`, `TokenRestrictedSids`, `TokenIntegrityLevel`, `TokenElevation`, `TokenUIAccess`, `TokenPrivileges`, `TokenType` y, si existe impersonación del hilo, su token efectivo. Consulta también pertenencia a Job y restricciones externas relevantes. Registrar SID de usuario de prueba/IL y privilegios sin tokens de acceso ni secretos.

Un padre ya restringido, IL distinta de media o elevado declara **«entorno no representativo»**. No llama «token ordinario» a `CreateProcessW` que hereda el token del sandbox de Codex. No obtiene el token de Explorer ni se despoja del sandbox. La corrida provisional puede registrar el diagnóstico, pero ninguna negativa cuenta como protección SEC5 y ningún control positivo fallido cuenta como defecto del mecanismo. Las mediciones válidas las vuelve a ejecutar el coordinador fuera de Codex con usuario estándar en Windows 11 Pro 26200. Ese sistema/usuario son el objetivo aportado; **NO VERIFICADOS aquí**.

### 4.2 Secuencia obligatoria

1. Validar autoridad, entrada, entorno, handles y destinos; persistir intento. Preparar el fixture propio y su plan de restauración antes del hijo.
2. Abrir token primario propio con `TOKEN_QUERY`, `TOKEN_DUPLICATE`, `TOKEN_ASSIGN_PRIMARY`, `TOKEN_ADJUST_DEFAULT` y los derechos realmente usados. No usar token aportado por un cliente.
3. Generar SID de lease no reutilizado mediante aleatoriedad del SO; guardar su representación binaria/string en la lease. No es una cuenta, un secreto ni el SID del usuario. Colisión comprobada se rechaza.
4. `CreateRestrictedToken(DISABLE_MAX_PRIVILEGE | WRITE_RESTRICTED)`, lista restrictiva con **solo ese SID** (`Attributes=0`); grupos administrativos presentes como deny-only. No introducir Everyone, Users, Authenticated Users o SID de logon en la lista restrictiva. Verificar SID/resultados en el token, no inferirlos de los flags.
5. `SetTokenInformation(TokenIntegrityLevel)` con `S-1-16-4096` y `SE_GROUP_INTEGRITY`; consultar de vuelta. Verificar privilegios efectivos: únicamente `SeChangeNotifyPrivilege` puede permanecer utilizable; no debug, impersonation, assign-primary, restore, backup, take-ownership, relabel o create-global. `DISABLE_MAX_PRIVILEGE` tiene tratamiento propio; no confiar en un array de borrado que ese flag ignora. [Contrato de CreateRestrictedToken](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-createrestrictedtoken).
6. Verificar política mandatory no-write-up, `TokenUIAccess=0` y virtualización desactivada/no aplicable. No cambiar la sesión ni elevar. Fijar `TokenDefaultDacl` para nuevos objetos internos conforme a §5.
7. Crear Job no heredable. Configurar `KILL_ON_JOB_CLOSE` y `DIE_ON_UNHANDLED_EXCEPTION`, sin `BREAKAWAY_OK` ni `SILENT_BREAKAWAY_OK`. P1 no necesita límites arbitrarios de toolchain ni restricciones GUI del Job.
8. Construir `STARTUPINFOEXW`, atributos y bloque UTF-16. Cada handle permitido es heredable; los extremos del padre no lo son. Usar `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` y `bInheritHandles=TRUE` cuando haya lista; sin handles, `FALSE` y sin herencia general. Jobs, tokens, pins, journals, locks y handles de proceso del broker nunca se incluyen. [Lista explícita de handles](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute).
9. `CreateProcessAsUserW` con ejecutable absoluto, command line mutable, cwd validado, `CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW`. Stdio por pipes; sin ventana ni ConPTY en P1.
10. Asignar al Job **antes** de reanudar; comprobar configuración y `IsProcessInJob` contra ese Job, no solo «pertenece a algún Job». Consultar desde el padre el token efectivo del hijo, registrar PID y hora de creación y confirmar que corresponden a los handles devueltos.
11. Persistir estado listo para ejecución. Comprobar `ResumeThread`; para un hilo inicial creado suspendido se espera contador previo 1. Cualquier resultado anómalo bloquea y termina el árbol fixture.

La exención documentada de `SeAssignPrimaryTokenPrivilege` para una versión restringida del token propio **no demuestra** que `CreateProcessAsUserW` funcione en este equipo ni elimina toda condición de cuota. Si devuelve **1314** u otro bloqueo de privilegios, P1 **para**: guardar API, flags, token/privilegios consultados, código decimal/hex y mensaje del SO; no intentar otros lanzamientos como workaround. [CreateProcessAsUserW](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessasuserw).

Alternativas que se documentarán si ocurre el bloqueo, sin ejecutarlas como sustitución: evaluar un mecanismo que conserve el token restringido sin pedir nuevos privilegios, o AppContainer con broker/capacidades revisados. Ambas necesitan diseño y medición nuevos y pueden no ser viables. `CreateProcessWithTokenW` tampoco se presume libre de privilegios; `CreateProcessWithLogonW` requiere credenciales. Quedan excluidos elevar, pedir credenciales del propietario, activar modo desarrollador y usar `CreateProcessW` ordinario como si aislara. Detener P1 con un bloqueo medido es un resultado válido.

### 4.3 Propiedad y errores

`OwnedProcess` posee proceso, hilo, Job, pipes, pins y referencia a lease. Si cualquier paso falla antes de reanudar: conservar error primario, terminar el proceso suspendido si existe, esperar su handle, cerrar recursos y restaurar el fixture; un fallo de limpieza también se reporta y deja estado bloqueado. No se cierra simplemente el handle de un proceso suspendido.

Después de reanudar, cancelación/timeout termina el Job y espera `ActiveProcesses=0` consultado al Job; una notificación de completion port es aviso, no la única prueba. No se interpreta el handle de Job como evento genérico de árbol vacío. Detached conserva propietario y lease hasta ese estado. Cierre del último handle de Job termina descendientes; no se filtra ni duplica a procesos no supervisados. Jobs anidados externos pueden impedir asignación/breakaway: medir y reportar, nunca retirar el Job para hacer funcionar el hijo. [Ciclo y límites de Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects).

## 5. Objetos de sesión, IPC y frontera de UI

### 5.1 Regla de capacidades

`TokenDefaultDacl` solo participa en la creación de objetos sin descriptor explícito. **No altera** objetos preexistentes de `\BaseNamedObjects`, la estación `WinSta0`, escritorios ni pipes. Conservar SID de logon en los grupos ordinarios no lo añade a la lista restrictiva. No corregir una incompatibilidad concediéndole escritura a esa lista.

| Objeto | Política S prevista | Medición y consecuencia |
|---|---|---|
| `\Sessions\<sesión>\BaseNamedObjects` / `Local\` | No se concede acceso de escritura al directorio de objetos de la sesión. Los objetos del producto se crean nuevos, con nombre aleatorio ligado a lease, SD explícito y permisos mínimos. No se reutiliza un objeto existente solo porque coincida el nombre. | Medir apertura por nombre y creación de objetos internos. Si el namespace impide crear objetos requeridos, bloquear el flujo o usar handles anónimos; no ampliar la sesión completa. |
| `Global\` | No es transporte S por defecto; sin adquirir `SeCreateGlobalPrivilege` ni compartir objetos globales privilegiados. | P2/P6 prueban necesidad específica; no asumir que todos los tipos tienen las mismas reglas de creación. |
| Evento preexistente del padre | No se autorizan cambios con `EVENT_MODIFY_STATE`. Consultar/sincronizar solo según DACL y política reales. | P1 intenta abrir con esa máscara y hacer `SetEvent` en fixture; padre mide señal. Resultado **NO VERIFICADO**, sin denegación inventada. |
| Mutex preexistente del padre | No se autoriza interferir adquiriendo/liberando el mutex. Evaluar `SYNCHRONIZE` además de `MUTEX_MODIFY_STATE`: la máscara no basta para deducir que una espera sea inocua. | Fixture nuevo; padre mide adquisición/bloqueo y liberación con barreras. Resultado **NO VERIFICADO**. |
| Eventos/mutexes internos nuevos | Broker crea con SD explícito: DACL ordinaria del propietario/SYSTEM y ACE del lease limitada a operaciones del canal; etiqueta baja si la operación la necesita. Retiene handle e identidad/nombre. | Positiva aparte con el mismo token S. Objeto preexistente/squatting provoca bloqueo, no adopción. |
| Pipe con nombre existente del padre | Sin autorización implícita para conectar/escribir. DACL/etiqueta del pipe y derechos de cliente/servidor se miden por separado. | P1 padre crea pipe fixture; registra conexión, bytes recibidos y token del cliente si se consulta. [Seguridad de pipes con nombre](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights). |
| Pipe con nombre propio de lease | Solo si necesario: descriptor explícito, derecho mínimo de conexión/datos, nombre aleatorio y primer servidor no preexistente. Autenticar cliente y contexto de lease; el servidor no ejecuta órdenes privilegiadas genéricas por aceptar una conexión. | P6 mide transporte real y ataques. No conceder `GENERIC_ALL` ni crear instancia de servidor como atajo para acceso de cliente. |
| Pipes anónimos de stdio | Capacidad deliberada mediante handles mínimos en la lista; no dependen de reabrir un nombre por DACL. El canal solo transporta stdin/stdout/stderr. | P1 padre envía nonce, recibe salida exacta en stdout y stderr. La herencia de un handle concede una capacidad real: no pasar canales del motor ni handles de archivos exteriores. |
| `WinSta0` y escritorio normal | P1 no crea ventanas, no cambia DACL/etiqueta, no añade ACE de lease, no consume clipboard/global atoms ni conmuta escritorios. Puede medir apertura de estación con máscaras concretas sin usar sus recursos. | Reportar acceso real y fallo de inicialización; `CREATE_NO_WINDOW` no significa estación privada ni aislamiento de mensajes. GUI queda fuera de P1. |

Para objetos nuevos creados por el hijo sin SD explícito, la DACL predeterminada lleva permisos mínimos del lease para objetos internos y los necesarios del broker/SYSTEM. Su efecto y la etiqueta efectiva se prueban sobre objetos nuevos; no se usa como autorización de objetos existentes. Un programa puede pedir otro SD al crear un objeto: la DACL predeterminada no es una política imposible de cambiar por el programa.

Los negativos de evento/mutex/pipe llevan control ordinario sobre el mismo fixture y una positiva autorizada separada cuando se implementa el canal de lease. Se guardan los descriptores usados, máscara, identidad del cliente y efectos medidos por el padre. «Se midió ALLOWED» no se transforma en PASS de aislamiento; es un resultado de caracterización que puede bloquear un flujo.

### 5.2 Transportes y escritorio posterior

Una positiva de stdio valida únicamente pipes anónimos y esos handles. No demuestra MCP, LSP, ConPTY ni un servidor con nombre. P6 debe completar petición/respuesta MCP y LSP con procesos reales, cierre/cancelación, reconexión y autenticación de sesión; ConPTY tiene su propio gate. Si un canal falla con S, documentarlo como incompatibilidad necesaria; no convertir el servidor a E.

P8 estudia estación y escritorio como objetos distintos. Un escritorio `WinSta0\Beats-<lease>` no es una estación privada y puede conservar capacidades compartidas como clipboard/atoms. Debe probar DACL y segunda comprobación de acceso de ambos objetos, etiquetas, mensajes, presentación, retorno seguro al escritorio humano y limpieza con fallos/crash. Se prohíbe abrir `WinSta0` ampliamente para resolver una prueba. [Derechos de estación de ventanas](https://learn.microsoft.com/en-us/windows/win32/winstation/window-station-security-and-access-rights).

Mientras GUI continúe en escritorio normal según decisión del propietario, se muestra «sin aislamiento de UI». Tampoco el WebView2 compartido de la cabina recibe el token S por envolver su API. Preview de código del modelo no se considera aislado por quitar el bridge; su separación es una mejora con gate propio. **Todo este comportamiento UI es NO VERIFICADO**.

## 6. Preparación, derechos y soporte de destinos

### 6.1 Descriptores y derechos reales

La preparación conserva por objeto: identidad de volumen/FileId, propietario, grupo primario, DACL completa (orden y bytes de ACEs), control del descriptor y etiqueta MIC (SID, máscara y flags de herencia). La decisión del coordinador del 10-oct-2026 redefine «restauración exacta» como igualdad semántica: una etiqueta ausente, una SACL nula y una SACL sin ACE `ML` son equivalentes (integridad efectiva media). Una ACE media explícita conserva su representación y sus campos.

Etiquetado, captura y restauración operan sobre el **handle retenido** mediante `SetKernelObjectSecurity`/`GetKernelObjectSecurity`, sin propagación automática. `SetSecurityInfo`/`SetNamedSecurityInfo` quedan excluidos de esos caminos; la única llamada de restauración con `SetSecurityInfo` pertenece al defecto sembrado `restore-auto-inherit`. El lanzador modifica la etiqueta del **token** con `SetTokenInformation(TokenIntegrityLevel)`; no etiqueta ni restaura objetos. Microsoft recomienda las API de alto nivel para filesystem; este P1 usa deliberadamente la API de kernel según la orden y las mediciones del coordinador, con certificación limitada a los fixtures NTFS medidos. [Contrato de SetKernelObjectSecurity](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-setkernelobjectsecurity), [descriptor autorrelativo leído por handle](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-getkernelobjectsecurity).

Consultar OWNER/GROUP/DACL/LABEL requiere `READ_CONTROL`; escribir DACL requiere `WRITE_DAC`; escribir propietario/grupo o etiqueta requiere `WRITE_OWNER`. Consultar/escribir la SACL de auditoría completa y alterar su protección tiene requisitos distintos (`ACCESS_SYSTEM_SECURITY`/privilegio de seguridad). Una llamada solo con `LABEL_SECURITY_INFORMATION` no concede esos derechos ni demuestra que se haya capturado toda la SACL. [Derechos por componente](https://learn.microsoft.com/en-us/windows/win32/secauthz/security-information).

`SeRelabelPrivilege` es un privilegio del token, **distinto de `WRITE_OWNER` sobre el objeto**. No se presume disponible para el usuario estándar ni se le agrega. Microsoft documenta la posibilidad de bajar la etiqueta de objetos propios sin ese privilegio; elevar por encima del IL del llamador o relabel de objetos ajenos requiere condiciones adicionales. **Restaurar baja→media o quitar la ACE para recuperar ausencia original debe medirse**, no deducirse de que bajar funcionó. [Modify an object label](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/security-policy-settings/modify-an-object-label).

Precondiciones para cada tipo de objeto:

1. Padre representativo medio; registrar presencia/atributos de `SeRelabelPrivilege`, sin habilitar privilegios nuevos.
2. Abrir el mismo objeto retenido con `READ_CONTROL | WRITE_DAC | WRITE_OWNER` y derechos de atributos necesarios; éxito real, no prueba por ser propietario. Reapertura por FileId verifica identidad, no por ruta mutable.
3. Construir fixture propio del mismo tipo con descriptor explícito: poner baja, leerla, restaurar etiqueta media y también ausencia original en un caso distinto, comprobar descriptor íntegro. Probar error por `WRITE_OWNER` ausente con handle reducido sobre fixture.
4. Antes de cualquier lease real, acreditar derechos de preparación **y de restauración** de cada objeto. Un descriptor ajeno cuya restauración de propietario necesite `SeRestorePrivilege` queda fuera; no tomar propiedad para poder prepararlo.
5. Fallo en apertura, setter, lectura de vuelta o comparación bloquea antes del spawn. Tras preparación parcial, restaurar lo registrado; cualquier fallo deja raíz bloqueada con diagnóstico exacto.

P1 solo modifica directorios/archivos, claves/objetos de sesión **creados por la prueba**. No etiqueta workspaces ni objetos existentes del usuario. Las consultas de derechos a `WinSta0` no la modifican.

### 6.2 Descriptor completo y SACL no accesible

El dominio mínimo soportado tiene descriptor íntegramente conocido: OWNER/GROUP/DACL/control y SACL formada únicamente por la etiqueta, o ausencia explícita, como los fixtures construidos por el broker. El journal almacena el descriptor binario autorrelativo completo de ese dominio, no únicamente SDDL OWNER+DACL.

Para un objeto preexistente con SACL de auditoría, atributos/política adicionales o control no restituible, se exige capturar y preservar todos sus componentes con derechos reales. Si el usuario estándar no puede leerlos o restaurarlos, **ese objeto no es preparable**: usar copia nueva privada cuando preserve la operación, o bloquear. Una consulta LABEL filtrada no prueba ausencia de ACEs de auditoría; no inventar descriptor «completo» a partir de ella. P2 no baja recursivamente una raíz heredada cuya seguridad no pueda reconstruir.

Comparación final de `SEC5 LABEL standard user roundtrip`, sin renombrar la prueba:

- Identidad exacta del objeto retenido y propietario/grupo iguales por SID.
- DACL: presencia/nulidad, revisión, bits `SE_DACL_PROTECTED` y `SE_DACL_AUTO_INHERITED`, y lista ordenada de ACE byte a byte. No ordenar ni descartar duplicadas; padding libre y offsets del descriptor no son permisos.
- Etiqueta efectiva: ausente ≡ SACL nula ≡ SACL sin ACE `ML`. Si existen ACE `ML`, debe coincidir la secuencia y cada tipo, flags, máscara y SID.
- Los cambios de `SE_SACL_PRESENT` y `SE_SACL_AUTO_INHERITED` se imprimen siempre como `SACL_CONTROL_DIFF=0x…`, con controles inicial/final y ambos bits separados; no provocan fallo. **Toda otra diferencia sí falla y bloquea**, incluidos otros bits de control y cualquier ACE no `ML` inesperada que difiera. No se convierte una consulta LABEL en prueba de ausencia de auditoría en objetos ajenos.

Mediciones del coordinador **fuera del sandbox**, conservadas bajo `la documentación interna`:

| Archivo | Resultado observado |
|---|---|
| `orq-sddl_probe-20261010.py`, salida `orq-label-medicion-20261010.txt` | `S:P` (media y vacía) falla con 1314 en usuario estándar; `S:(ML…ME)`, `S:(ML…LW)` y ausencia funcionan. Se mantiene la SACL sin `P`; no se solicita `SeSecurityPrivilege`. |
| `sec5-baseline-20261010-005204-633-02.txt` (serie `sec5-baseline-20261010-*.txt`) | Ambos ejecutables compilan; el roundtrip con `SetSecurityInfo` falla en comparación binaria y bloquea. DACL `D:P` pasa a `D:PAI` y se añade `S:AI`, según la comparación del coordinador. |
| `orq-label_roundtrip-20261010.py`, salida `orq-label-medicion-20261010.txt` | Con `SetKernelObjectSecurity`, DACL idéntica. Ausencia inicial termina en `S:NO_ACCESS_CONTROL` (`SE_SACL_PRESENT` cambia); `S:AI(ML…ME)` termina en `S:(ML…ME)` (`SE_SACL_AUTO_INHERITED` cambia). La etiqueta efectiva queda igual; la comparación binaria sigue siendo falsa. |

La mutación `restore-auto-inherit` restaura **solo el roundtrip** mediante `SetSecurityInfo`. Debe producir FAIL por `DACL_CONTROL_DIFF=0x0400` (`SE_DACL_AUTO_INHERITED`, `D:P` → `D:PAI`), aunque la etiqueta efectiva coincida. El wrapper exige ese diagnóstico además del FAIL nominal y resumen BLOCKED; error de API, compilación o entorno no representativo no acredita rojo. Luego el fixture intenta reparación con la API de kernel, y el wrapper exige baseline restaurada verde. Las diferencias SACL permitidas nunca ocultan cambios DACL.

El `WIN32=87` posterior al fallo en la baseline citada procedía de `LastError` residual: la comparación devolvía FALSE sin establecer un error. El comparador ahora fija `ERROR_INVALID_SECURITY_DESCR` (1338) para diferencias semánticas; el roundtrip conserva el error antes de imprimir/liberar/borrar y lo devuelve al diagnóstico de preparación. Los fallos de API mantienen su código original. La medición del resultado corregido en usuario estándar corresponde al coordinador.

### 6.3 Etiqueta y ACE de lease

Directorio destino nuevo: etiqueta baja `S-1-16-4096`, `SYSTEM_MANDATORY_LABEL_NO_WRITE_UP`, herencia `OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE`; DACL con permiso ordinario del padre y ACE de lease para datos, crear entradas/hijos, atributos y borrado de hijos autorizado. No concede `WRITE_DAC`, `WRITE_OWNER`, `ACCESS_SYSTEM_SECURITY` ni borrado/renombre de la raíz de control. Permisos de datos y etiqueta son mecanismos independientes.

El hijo conserva el SID del usuario propietario. Por ello se deben medir derechos implícitos de propietario y usar ACE `OWNER RIGHTS` donde sea necesaria para impedir `WRITE_DAC` implícito, además de la segunda comprobación restrictiva y MIC. No basta con omitir ese derecho de una ACE de lease. El broker conserva concesiones explícitas y handles de reparación; comprobar que S no puede cambiar DACL, subir/quitar label ni ampliar otra lease. [Propietario de un objeto nuevo](https://learn.microsoft.com/en-us/windows/win32/secauthz/owner-of-a-new-object).

No propagar permisos indiscriminadamente a árboles reales. Objetos existentes se inventarían y journalizan individualmente; los protegidos no se asumen heredados. Rechazar reparse points y archivos con más de un hardlink antes de modificar: el descriptor pertenece al objeto, no al nombre, y puede afectar una ubicación exterior. P2 añade pruebas de links y de carreras; un scan por nombre seguido de propagación recursiva no cierra esa carrera.

Objetos nuevos dentro de la lease se enumeran y registran por identidad tras árbol vacío. Artefactos retenidos se devuelven al descriptor final de publicación definido por el broker (medio, sin SID de lease); temporales propios pueden borrarse según política. No existe descriptor «inicial» de un objeto creado por el hijo. Si no se puede enumerar/certificar el conjunto o aparece un enlace inseguro, bloquear publicación y recuperación; no afirmar restauración completa de toda la raíz por reparar solo su descriptor.

### 6.4 Lista de soporte

Lista de admisión v2; **ningún volumen está certificado todavía**. La selección conservadora de NTFS es una condición del diseño, no una afirmación de que ReFS no tenga capacidades.

| Sistema/volumen | Política |
|---|---|
| NTFS local fijo, volumen identificado por GUID + serial y handles retenidos | Único candidato admitido. Exige `FILE_PERSISTENT_ACLS`, `FILE_ID_INFO` de 128 bits, reapertura por ID comprobada, operaciones LABEL, restauración íntegra y journal durable funcionando. P1 empieza por fixtures nuevos en el volumen C: del equipo, si acredita todo eso. |
| Otro volumen NTFS fijo local | Bloqueado hasta repetir los gates por volumen, registrar identidad/capacidades y tener recuperación local comprobada. Una letra de unidad no es una identidad. |
| NTFS remoto/SMB/UNC, unidades mapeadas de red, DFS | Bloqueado; no extrapolar identidad, locking, labels o durabilidad de NTFS local. |
| FAT/FAT32/exFAT, ReFS, RAM disks, proveedores virtuales/no identificables, volúmenes extraíbles/ópticos, read-only | Bloqueado en esta versión, aunque un caso particular ofrezca alguna API. |
| WSL, rutas de contenedor/servicio externo, cloud placeholders/reparse, junction/symlink, mount atravesado sin identidad independiente | Bloqueado como destino S de este mecanismo. Resolver a una raíz admitida retenida o materializar copia; nunca seguir el enlace para etiquetar. |

Registrar GUID, serial, tipo, filesystem y flags desde handles, sin recorrer datos de usuario. Detectar sustitución/desmontaje/cambio de identidad como fallo. Raíces multivolumen exigen leases separadas de volúmenes certificados y adquisición ordenada. Si no se puede garantizar identidad después de reinicio —incluida posible reutilización de FileId—, se bloquea recuperación; no restaurar un objeto nuevo que casualmente ocupe el nombre anterior. [Identificación de volumen por handle](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getvolumeinformationbyhandlew), [reapertura por FileId](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-openfilebyid).

## 7. Exclusión S/E, journal y recuperación interproceso

P1 usa solo un fixture y restauración local; esta sección es el contrato obligatorio de P2, **NO VERIFICADO**. No autoriza tocar raíces reales en P1.

### 7.1 Medio, identidad y defensa contra squatting

La exclusión se implementa mediante **archivo de lock y `LockFileEx` exclusivo sobre el byte 0**, mantenido durante toda la lease, en una raíz de control media del broker fuera de destinos S. No un mutex predecible de `Local\` ni un lock por string de ruta. El archivo no se usa mediante memory mapping. Cierre/caída libera el lock del SO, pero **no** da por restaurados los permisos. [Bloqueos de rangos de archivo](https://learn.microsoft.com/en-us/windows/win32/fileio/locking-and-unlocking-byte-ranges-in-files).

Clave de raíz: serialización versionada de `{VolumeGuid, VolumeSerialNumber, FILE_ID_128}`; nombre del lock = SHA-256 de esa serialización. El contenido incluye la identidad completa para rechazar colisiones o reemplazos. Casing, letras de unidad, rutas cortas o aliases del mismo objeto no crean locks distintos.

Raíz de control, catálogo, locks y journal: propietario del broker/usuario y SYSTEM con concesiones explícitas; DACL protegida sin escritura de Everyone/Users/Authenticated Users/lease; etiqueta media explícita no-write-up. No son heredables. El hijo bajo no recibe sus handles. Antes de usar un directorio o archivo ya existente, validar propietario, label, DACL, identidad, formato/contenido, ausencia de reparse y link count 1. Creación inicial usa nombre nuevo/`CREATE_NEW`; un preexistente no reconocido no se borra ni adopta, sino que bloquea con `ControlObjectUntrusted`.

Pins de raíz de control/ancestros y handles de lock sin compartir DELETE impiden reemplazo durante el uso. Un nombre aleatorio es defensa adicional, no autenticación; la autenticación viene de identidad y descriptor en almacenamiento medio validado. Un proceso medio malicioso de la misma cuenta, incluidos E, puede tener capacidades del propietario: eso permanece fuera del aislamiento admitido, no se atribuye a esta DACL una defensa contra él.

Un catálogo durable de raíces y rangos protegidos usa otro lock de archivo con la misma política. Bajo ese lock se verifican raíces iguales o solapadas por ascendencia **por handles**, se consultan journals pendientes y se adquieren los locks de raíces en orden lexicográfico de identidad. La adquisición es no bloqueante (`LOCKFILE_FAIL_IMMEDIATELY`); conflicto devuelve `LeaseBusy` y libera el catálogo. Así no se espera por un propietario que necesita el catálogo para finalizar. Las leases activas/pending registradas impiden que dos FileIds distintos de raíz/descendiente eviten la exclusión por solapamiento.

Publicar reserva durable en catálogo antes de soltarlo. El lock de raíz permanece hasta restauración comprobada, incluidos detached. Al finalizar se usa el catálogo para publicar cierre y liberar reserva. En el siguiente inicio se reconcilia catálogo/journal bajo lock antes de admitir nuevos lanzamientos; registro huérfano no se descarta por antigüedad ni por PID inexistente. Un SID de lease jamás se regenera al recuperar.

### 7.2 Journal previo y durable

Journal versionado por lease, en la misma raíz de control admitida; no en el workspace bajo ni en un JSON que S pueda escribir. Registros append-only con longitud, versión, secuencia, tipo, hash/checksum y referencia al registro anterior. Hash encadenado detecta corrupción/cola parcial; no autentica frente al propietario medio. Escribir con política write-through y `FlushFileBuffers` comprobado **antes** de cualquier mutación o avance que dependa del registro. No truncar registros de evidencia ni borrar journal pendiente.

La publicación inicial crea journal nuevo, vacía a almacenamiento, y confirma una entrada durable en el catálogo antes de mutar. Fallo de flush/publicación no permite cambiar permisos. Tras crash, validar desde inicio hasta último registro completo; una cola incompleta después de PREPARE_INTENT mantiene la raíz pendiente, pues no prueba si hubo mutación. El diseño cubre crash/reinicio del proceso sobre almacenamiento local que cumple flush; tolerancia a pérdida de energía/controlador es **NO VERIFICADA**, no se promete solo por usar un rename.

Datos mínimos persistidos:

| Grupo | Campos |
|---|---|
| Lease/autoridad | ID, versión, categoría S/E, SID de lease binario y string para S; E registra ausencia explícita, propietario de broker, orden/superficie/permiso y generación. |
| Identidad | GUID y serial de volumen, filesystem/capacidades, FileId de raíz y cada objeto, tipo, creación y validadores de generación, ancestría; ruta solo como localizador/diagnóstico. |
| Seguridad | Descriptor completo original y preparado por objeto, control separado, hashes; etiqueta presente/ausente y bytes de ACE; derechos y privilegios acreditados para restaurar. |
| Plan | Inventario de objetos a modificar, concesiones, objetos nuevos, política de artefactos/temporales, entrada autorizada y estrategia. |
| Árbol | ID/nombre aleatorio de Job si se usa recuperación por nombre, SD/configuración del Job, propietario PID+hora de creación, identidad de arranque del SO, procesos conocidos PID+hora, estados de spawn suspendido/asignado/reanudado y cierre comprobado. |
| Transiciones | Intención antes de cada setter, resultado/lectura de vuelta, RESTORE_INTENT, estado restaurado, TREE_CLOSED, errores exactos y COMMITTED_FINAL. |

No persistir valores numéricos de handles como si fueran reutilizables tras reinicio. Reabrir por identidad validada, comparando también generación/validadores; desaparición, reutilización posible o identidad divergente bloquea. No seguir una ruta antigua hasta otro objeto para aplicarle el descriptor.

### 7.3 Máquina de estados e idempotencia

| Estado durable | Invariante | Acción de recuperación bajo exclusión |
|---|---|---|
| RESERVED | Reserva registrada; ninguna mutación autorizada aún | Verificar catálogo y descriptores; cerrar reserva si originales coinciden. |
| SNAPSHOT_DURABLE | SID, inventario y originales completos vaciados; sin setters autorizados | Si todo coincide con original, finalizar; divergencia no explicada bloquea. |
| PREPARE_INTENT(i) / PREPARING | Puede haberse modificado cualquier objeto con intención, aunque falte ACK | Árbol no reanudado según estado durable; verificar/terminar cualquier spawn incierto, luego restaurar cada objeto con intención, comparando con original. Repetir setters solo cuando difiere y son seguros. |
| PREPARED | Todos los preparados coinciden; no hay ejecución autorizada todavía | Restaurar si se aborta; no continuar un lanzamiento antiguo tras reinicio sin autoridad nueva. |
| SPAWN_INTENT / SUSPENDED / ASSIGNED | Puede existir hijo suspendido no completamente registrado | Terminar solo el árbol propio acreditado; si no se puede identificar/certificar, RECOVERY_BLOCKED. Nunca interpretar ausencia de PID registrado como ausencia de proceso. |
| RUN_INTENT / RUNNING | Puede haber ejecutado código; toda la lease queda pendiente | Confirmar/forzar cierre del Job propio y árbol; reconciliar objetos nuevos antes de restaurar. |
| TREE_CLOSED | Árbol vacío certificado y registrado; no se puede volver a reanudar | Reabrir identidades y continuar restauración. |
| RESTORE_INTENT(i) / RESTORING | Algunos originales pueden estar repuestos aunque falte ACK | Si descriptor ya coincide, registrar sin reescribir; si no, restaurar y leer de vuelta. Fallo no libera raíz. |
| RESTORED | Todos los originales coinciden; artefactos publicados/temporales resueltos | Revalidar conjunto, registrar COMMITTED_FINAL y después cerrar reserva/locks. |
| COMMITTED_FINAL | Sin SID residual, permisos finales y árbol comprobados | Reconciliar catálogo huérfano idempotentemente; conservar journal de evidencia. |
| RECOVERY_BLOCKED | Identidad, árbol, descriptor, volumen o registro ambiguos | Bloquear S/E sobre cualquier raíz solapada. Reintento explícito; no borrar journal, levantar bloqueos ni restituir por nombre a ciegas. |

La intención se vacía antes del setter; el ACK se vacía tras lectura de vuelta. La recuperación de PREPARING restaura todos los objetos con intención aunque el último setter no haya retornado; nunca depende de un ACK para decidir si debe reparar. Crash durante la reparación repite el mismo algoritmo.

No se restaura mientras un proceso pueda escribir. Job sin breakaway, sin handles filtrados, cierre comprobado y reserva previa reducen incertidumbre; no eliminan la ventana entre crear un proceso y persistir su identidad. Se registra SPAWN_INTENT antes de crear, se crea suspendido y se mantienen retenciones; si tras crash no puede acreditarse qué ocurrió, queda bloqueado. Para Job recuperable por nombre, usar nombre aleatorio persistido antes de crear, descriptor medio validado, rechazo de preexistencia y pertenencia/configuración comprobadas; solo TerminateJobObject sobre el Job propio acreditado, esperando `ActiveProcesses=0`. Abrirlo al recuperar añade un handle: no confiar entonces en que KILL_ON_JOB_CLOSE ya haya ocurrido.

Si el Job ya no existe, el diseño solo acepta cierre cuando tiene prueba suficiente del propio árbol (estado TREE_CLOSED durable, o garantías de cierre/identidad verificadas para esa corrida); no basta `OpenProcess` fallido, PID ausente o timeout. En caso contrario queda RECOVERY_BLOCKED. Tras reinicio completo acreditado del SO no sobreviven procesos del arranque anterior, pero todavía se verifican identidades/descriptores y objetos nuevos antes de restaurar. La disponibilidad de recuperación automática de todos los crashes es **NO VERIFICADA**; bloquear de forma segura es preferible a certificar una recuperación no demostrada.

### 7.4 Convivencia S/E y snapshot existente

Secuencia única por raíz:

```text
sin journal pendiente / sin lease
  -> exclusión + reserva + snapshot durable
  -> S: preparar baja/ACE -> árboles dentro del Job -> árbol vacío
     o E: snapshot completo -> CLI exceptuado -> cierre comprobado
  -> restaurar/conciliar -> comparar descriptor completo
  -> COMMITTED_FINAL -> liberar reserva y exclusión
```

S y E no se intercalan. Tampoco dos sesiones/procesos del producto pueden capturar un «original» mientras otro ya mantiene una DACL temporal. El cierre de un proceso principal no libera la lease si quedan descendientes. Si E usa una delegación externa cuyo cierre no puede acreditarse, no restaura como si hubiera terminado todo: deja recuperación pendiente. El riesgo aceptado E no justifica declarar segura la coexistencia.

En el código actual, `da_workspace_permissions_capture`, `workspace_live_descriptor`, `workspace_descriptor_sddl` y `workspace_compare` de `external_cli_security.c` usan OWNER+DACL y control; no capturan/comparan LABEL. `workspace_descriptor_restore` pide `WRITE_DAC` y `WRITE_OWNER` cuando cambia owner, y tiene reparación por handle. `workspace_acl.zig.Snapshot` expone esa semántica. Esto está comprobado por lectura, no por pruebas nuevas.

P2 amplía el **mismo snapshot** y comparación a GROUP/LABEL y al descriptor íntegro del dominio soportado, preservando ausencia/flags/control; requiere `WRITE_OWNER` también cuando cambia label, aunque owner coincida. Actualiza exportación/importación durable, SDDL diagnóstico y fachada versionada si cambia contrato público. No clona un segundo restaurador independiente para S.

La restauración actual que detecta enlaces puede reparar solo raíz y devolver `DA_WORKSPACE_TREE_HAS_LINKS`. Eso no cuenta como éxito de retiro de S ni como permiso para iniciar E. La ampliación evita propagación por rutas no retenidas y verifica cada objeto del inventario; cualquier parte no certificada queda pendiente. Probar S→E y E→S en **dos brokers reales**, root aliases, crash en captura/setter/ACK/restauración y etiquetas inicialmente ausentes y explícitas.

## 8. Pruebas SEC5 y evidencia exigida

### 8.1 Disciplina de medición

Paso previsto `test-sec5-os`, separado de `test`: compila padre y `tests/sec5_child.zig`, pasa ruta absoluta del hijo/fixtures sin resolución por PATH y ejecuta hijos mediante `governed_process`. Fixtures de proceso objetivo y broker son subprocesos propios de la prueba. No se modifica ACL/label ni se termina un proceso ajeno. No se toca `%LOCALAPPDATA%\DevAgents`, claves ni `auth.json`.

Padre crea fixtures con GUID, SD explícito y marcadores nonce; retiene identidades y toma estado antes/después. Cada negativa usa un control con token ordinario representativo en **el mismo fixture**, limpiando solo sus efectos entre casos. Barreras explícitas distinguen «intentó la operación» de «no llegó a ejecutarse». Los reportes del hijo son diagnóstico; no prueban el efecto. Los campos de la tabla son criterios de la prueba futura, **no resultados actuales**.

Resultado por caso: `PASS` solo con control/observación completos; `FAIL` con efecto o control inesperado; `OBSERVED_ALLOWED`/`OBSERVED_DENIED` para caracterización de sesión; `BLOCKED`, `ENVIRONMENT_NOT_REPRESENTATIVE` o `SKIPPED` con razón. Un skip no suma una prueba aprobada. Conteos sin ejecución son nulos, no 0/0 verde. El paso devuelve no cero si falta una medición obligatoria o el entorno no representa usuario estándar; ausencia visible de node/python es una excepción de compatibilidad informada, nunca una positiva implícita.

### 8.2 Matriz P1 sin GUI

Todas las filas: **NO VERIFICADO; sin salida de ejecución en esta corrida**.

| ID / nombre exacto previsto | Fixture, control y medición del padre | Criterio o interpretación |
|---|---|---|
| SEC5 ENV parent representative | Token efectivo padre y contexto de Job; sin sustituirlo por otro usuario | Si restringido/IL no media/elevado, entorno no representativo; no dar verdes/rojos de seguridad. |
| SEC5 TOKEN effective child | Hijo retenido suspendido; padre abre token y consulta SID restrictivo, IL, tipo, UIAccess, policy/virtualization y privilegios | SID único de lease, IL bajo, política requerida y ausencia de privilegios peligrosos. Control ordinario medido aparte. |
| SEC5 MIC medium write denied | Directorio medio con DACL ordinaria **y ACE de lease** que permiten la misma escritura; control crea mismo marcador | S no crea/modifica marcador. Concede SID para aislar MIC; registrar label real. |
| SEC5 SID foreign low write denied | Directorio bajo con permiso ordinario y **sin ACE de lease**, fuera del destino; control escribe allí | S no escribe; MIC no lo impide por ser bajo. |
| SEC5 DEST prepared write allowed | Destino bajo con ACE de lease; hijo crea/escribe contenido nonce; padre lee por handle | Bytes correctos y únicamente cambios declarados. Positiva imprescindible para interpretar negativas. |
| SEC5 READ ordinary readable outside | Archivo medio fixture sin ACE de lease, read ordinario permitido; hijo copia nonce leído a stdout y padre compara | Lectura funciona bajo WRITE_RESTRICTED; discrimina la mutación sin ese flag. No promete confidencialidad. |
| SEC5 REG HKCU write denied | Padre crea `HKCU\Software\DevAgents-SEC5-<GUID>` medio y DACL ordinaria+lease para aislar MIC; control modifica valor exacto | Padre lee valor/enumera subclave, comprueba ausencia de cambio y virtualización. Borra solo fixture; positiva S en key baja autorizada aparte si se implementa. |
| SEC5 PROCESS VM_WRITE denied | Proceso objetivo propio medio con memoria nonce; control ordinary abre con PROCESS_VM_WRITE y, en fase aparte, VM_OPERATION para WriteProcessMemory | Padre lee memoria real del objetivo; S no altera y su apertura se mide. No heredarle handle al objetivo. |
| SEC5 PROCESS TERMINATE denied | Objetivo propio nuevo medio, control lo termina y padre espera señal; crear otro objetivo para S | Bajo S permanece vivo hasta limpieza propia del padre; no aceptar solo un texto «AccessDenied». |
| SEC5 SESSION event observed | Evento nombrado propio del padre, SD ordinario explícito; control OpenEvent(EVENT_MODIFY_STATE)+SetEvent | Padre mide señal y captura máscara/error. ALLOWED/DENIED observado, sin resultado inventado. |
| SEC5 SESSION mutex observed | Mutex nombrado propio, apertura por SYNCHRONIZE/MUTEX_MODIFY_STATE y adquisición con handshake; control equivalente | Padre mide interferencia/adquisición/liberación. No inferir de la máscara que es seguro. |
| SEC5 SESSION named pipe observed | Pipe con nombre del padre creado con SD explícito, sin SID de lease; control conecta/escribe nonce | Padre mide conexión y bytes/token de cliente; resultado de caracterización. |
| SEC5 SESSION authorized objects allowed | Evento/pipe nuevos de lease con SD/label definidos; mismo token S | Positiva de canal permitido; no altera los objetos anteriores para hacerlos funcionar. |
| SEC5 SESSION default DACL measured | Hijo crea evento nuevo sin SD; padre obtiene descriptor y prueba acceso con otro SID fixture/no autorizado | Comparar DACL efectiva con la solicitada; no usarlo para acreditar acceso a objetos existentes. |
| SEC5 SESSION WinSta0 access observed | Solo solicitudes de apertura con máscaras registradas (`WINSTA_READATTRIBUTES`, `WINSTA_ACCESSCLIPBOARD` separadas), sin consumir clipboard ni cambiar seguridad | Caracterización sin UI ni modificación de WinSta0; falla de runtime identificada. |
| SEC5 STDIO anonymous allowed | Padre envía nonce stdin, captura stdout y stderr distintos y exactos; pipes del padre no heredables | Las tres direcciones funcionan; EOF/cierre completan sin hang. Si falla, transporte stdio necesario incompatible. |
| SEC5 JOB breakaway denied | Hijo intenta nieto propio con CREATE_BREAKAWAY_FROM_JOB; padre mide resultado y marcador/membresía por handle/PID+hora | No puede crear nieto fuera del Job SEC5. Control ordinario fuera de Job confirma que fixture/flags funcionan. |
| SEC5 JOB normal grandchild contained | Hijo crea nieto sin flag de escape; padre obtiene identidad/handle y consulta IsProcessInJob contra Job SEC5 | Nieto real pertenece al Job; no basta el recuento declarado por hijo. |
| SEC5 JOB nested contained | Padre fixture crea un Job externo compatible y ejecuta el mismo lanzador dentro | Asignación/configuración exactas funcionan o bloqueo real documentado; no activar breakaway como workaround. |
| SEC5 JOB broker close kills tree | Broker fixture tiene único handle del Job; hijo/nieto vivos con identidad conocida. Padre espera salida normal y crash del broker en variantes separadas | Ambos handles de proceso quedan señalados por cierre del Job. Padre no retiene/duplica handle de Job de broker. |
| SEC5 HANDLE excluded not inherited | Evento inheritable extra del padre fuera de HANDLE_LIST, con evento testigo permitido separado; control de herencia general | Padre no observa señal del evento extra ni capacidad equivalente en hijo; comprobar objeto/nonce, no solo invalidez de un número de handle que podría reutilizarse. |
| SEC5 FAIL before resume no child | Inyectar fallo de configuración/asignación/persistencia inmediatamente antes de resume; marcador de primer acto del hijo en destino válido | Padre mide marcador ausente y handles de proceso señalados; registro del fallo conserva error primario y cleanup. |
| SEC5 LABEL standard user roundtrip | Directorio fixture con descriptor explícito, casos etiqueta ausente y media explícita; apertura con derechos reales, baja y vuelta | Descriptor final íntegro idéntico al inicial y misma identidad; registrar SeRelabelPrivilege del padre. |
| SEC5 LABEL missing WRITE_OWNER blocks | Handle fixture sin WRITE_OWNER, intento de preparación | Bloqueo exacto antes del hijo; descriptor sin cambios y control con handle correcto. |
| SEC5 LABEL inheritance measured | Destino bajo con OI/CI; hijo crea fichero/subdirectorio; otro fixture preexistente/protegido | Padre lee label/DACL efectivos; no extrapolar herencia de nuevos a existentes. Restituye raíz y resuelve artefactos nuevos según plan. |
| SEC5 SECURITY child cannot widen | Hijo intenta WRITE_DAC/WRITE_OWNER, quitar/subir label y ampliar otro SID sobre sus fixtures | Padre compara SD/control/label y controla positiva con token ordinario. Resolver OWNER RIGHTS si falla. |
| SEC5 NODE inline compatible | `node -e` real fijado, entrada inline fixture autorizada; escribe nonce solo en destino preparado, intenta exteriores fixture | Padre verifica datos y externos intactos; si node no está instalado, SKIPPED visible con búsqueda y razón. |
| SEC5 PYTHON inline compatible | `python -c` real fijado, mismos destinos/observaciones y control ordinary | Positiva independiente; ausencia visible, nunca descarga/instalación automática. |

La prueba de OpenProcess mide la apertura con cada máscara exigida y el efecto cuando se obtiene el handle. Para MEMORY, el padre conserva derechos de lectura propios; para TERMINATE, conserva un handle de espera. Fixtures ordinarios se recrean si el control positivo los termina. Las negativas no pasan si el hijo nunca llegó a intentar la operación o si el control ordinario está contaminado por el sandbox.

### 8.3 Pruebas de P2/P3 y posteriores

También **NO VERIFICADAS**, no condiciones que se atribuyan a un P1 todavía no ejecutado:

| Prueba prevista | Fixture / operación | Medición exigida |
|---|---|---|
| SEC5 LEASE crash matrix | Dos procesos fixture, interrupción tras reserva, snapshot/flush, cada PREPARE_INTENT, setter antes de ACK, PREPARED, SPAWN_INTENT, asignación, RUN_INTENT, cierre, RESTORE_INTENT/setter/ACK y antes de COMMITTED_FINAL. | Reiniciar recuperador dos veces; comparar originales, locks y bloqueo. |
| SEC5 LEASE S then E serialized / E then S serialized | Broker A mantiene S/descendiente vivo; B solicita E sobre mismo objeto/alias y viceversa; caída de ambos y reservas huérfanas. | B no captura/restaura mientras A tiene lease; termina A, recuperación completa y B funciona. |
| SEC5 LEASE squatting and overlaps | Precrear lock/control file/Job fixture con descriptor o identidad incorrectos; aliases y raíz-descendiente | Bloqueo sin adoptar/borrar objeto adversarial; exclusión por identidad y solapamiento. |
| SEC5 LEASE corruption / identity replacement | Cola parcial/checksum erróneo, original ausente, FileId/volumen cambiado, descriptor no representable | Recuperación bloqueada visible, cero setters a objeto sustituto, cero lanzamientos sobre raíz ambigua. |
| SEC5 FS unsupported volumes | Gate de lista, capacidades y handles fallidos; fixtures en volúmenes disponibles, skips explícitos si no existen | No se etiqueta ni lanza en volumen no admitido. No fingir prueba de filesystem real solo con enum simulado. |
| SEC5 FS links and concurrent substitution | Reparse/hardlinks propios, intento de sustituir nombres/ancestros mientras se prepara/restaura | Descriptor exterior fixture intacto; sin recorrer ubicaciones reales ni links ajenos. |
| SEC5 INPUT pin / private snapshot | Sustitución del fichero/ancestros, writer incompatible, cambio de bytes/hash y entrada inline diferente | Rechazo o copia privada de bytes exactos; ninguna aprobación antigua ejecuta entrada nueva. Snapshot transitivo con manifiesto si se anuncia tal garantía. |
| SEC5 PROVENANCE cards and dirty | MCP/.mcp/clone/E/hijo/desconocido, cambio de hash, doble reclamo entre procesos, crash de reconciliación | Tarjeta obligatoria, solo cabina, reclamo único, dirty no se vuelve humano. |
| SEC5 PROFILE S E T lifecycle | Por cada perfil migrado, Job/lease/handles, cancelación y cierre; E medido como exceptuado, no token S | Sin filtración de Job/desktops/pins; mutar KILL_ON_JOB_CLOSE por perfil para detectar descendientes vivos. |
| SEC5 IPC MCP LSP ConPTY | Procesos reales, peticiones, retorno, permisos de canales, cierre/crash y cliente ajeno | Compatibilidad y rechazo de intermediación no autorizada; failure bloquea flujo necesario. |
| SEC5 UI separate gate | Estación/escritorio, app real, cambio/retorno, mensajes, clipboard/atoms y crash | No es parte de P1; etiqueta «sin aislamiento de UI» solo se retira con evidencia propia. |

### 8.4 Mutaciones discriminantes

Cada mutación cambia una sola condición en fixture/configuración exclusiva de pruebas, conserva salida roja con `EXIT_CODE`, restaura bytes/configuración original y ejecuta verde de nuevo con su salida. Nunca se rebaja una aserción. Barreras deterministas evitan que el rojo dependa de ganar una carrera. Ninguna mutación se aplicó aquí: **NO VERIFICADO**.

| Mutación P1 | Prueba que debe ponerse roja y qué discrimina | Verde tras restaurar |
|---|---|---|
| Sin `SetTokenInformation(TokenIntegrityLevel)` | SEC5 TOKEN observa IL media; SEC5 MIC permite escritura porque su DACL **incluye ACE de lease**. No usar fixture sin ACE, que ocultaría la mutación. | IL baja y negativa MIC, positiva destino conservada. |
| Sin SID restrictivo | SEC5 TOKEN pierde SID; SEC5 SID permite escritura en bajo ajeno por DACL ordinaria. Conservar WRITE_RESTRICTED y todo lo demás. | SID presente, ajeno denegado y destino permitido. |
| Sin `WRITE_RESTRICTED` | El SID sigue restrictivo y también participa en lecturas; SEC5 READ falla, o el runtime no inicia por lecturas necesarias. No esperar una ampliación de escrituras: esta mutación endurece otros accesos. Registrar resultado exacto. | Lectura fuera del destino funciona y negativas de escritura siguen funcionando. |
| Con `BREAKAWAY_OK` | SEC5 JOB breakaway crea nieto fuera del Job propio; padre mide pertenencia/marker. Si un Job exterior lo sigue impidiendo, entorno no discrimina esta mutación: repetir en fixture representativo sin esa restricción, no atribuir rojo ficticio. | Escape denegado y nieto normal contenido. |
| Sin lista explícita de handles | Conservar `bInheritHandles=TRUE` y handle extra inheritable; SEC5 HANDLE obtiene capacidad/signal que estaba excluida. No mutar también herencia a FALSE. | Handle extra no llega; stdio sigue positivo. |
| Reanudar antes de asignar al Job | Barrera fixture permite primer acto/marcador y creación de nieto antes de asignación; SEC5 FAIL/JOB detecta proceso ejecutado o descendiente fuera. Inyectar fallo de asignación después de esa barrera para probar fallo cerrado. | Con asignación previa y fallo antes de resume no hay marcador ni proceso vivo. |
| Restaurar roundtrip con `SetSecurityInfo` (`restore-auto-inherit`) | `SEC5 LABEL standard user roundtrip` falla por `SE_DACL_AUTO_INHERITED`, `DACL_CONTROL_DIFF=0x0400`; las diferencias SACL permitidas siguen registradas. Solo se cambia el setter de restauración del roundtrip. | Restauración con `SetKernelObjectSecurity`, igualdad semántica de §6 y diagnóstico SACL; reparación local y baseline posterior obligatorias. |

P2 añade mutaciones de omitir snapshot LABEL, omitir flush previo/intención, omitir lock por identidad/solapamiento y restaurar antes de árbol vacío. Pruebas de sesión añaden omisión del SD/lease del canal propio y confusión TokenDefaultDacl→objeto existente, sin ampliar DACL reales de la sesión. P3 muta comparación identidad/hash y reclamo único. P7/P8 mutan KILL_ON_JOB_CLOSE en cada perfil aplicable y filtración de Job/escritorio; no se dan por cubiertas con el caso S de P1.

## 9. Compatibilidad y contratos que no se relajan

Todas las compatibilidades con el token nuevo son **NO VERIFICADAS**; las únicas positivas iniciales exigidas son hijo fixture, stdio, node y Python instalados. Las demás no se extrapolan de ellas.

| Flujo | Contrato previsto y bloqueo visible |
|---|---|
| Node/npm | Ejecutables instalados legibles; código/temporales/cache local bajos, `npm_config_cache` privado. Lifecycle y node-gyp quedan S. Mantener guard Node de verificaciones, incluido al reanudar H9. |
| Python/pip | Runtime instalado legible, temporal/cache/venv privados, flags de seguridad vigentes. `-E` puede ignorar variables PYTHON; no confiar solo en ellas. Tkinter/GUI pasa al gate P8. |
| PowerShell | `pwsh`, entrada autorizada, módulos instalados legibles y estado privado. No usar `ExecutionPolicy Bypass` como arreglo ni prometer compatibilidad de Known Folders. |
| Zig/cargo/go | Cache/global cache/output y estado de toolchain en lease; runtime instalado no escribible. Builds y auxiliares heredan S. Actualización global requerida bloquea. Límites por toolchain se miden después. |
| Git/gh en worktrees | `.git` exterior y metadata compartida **sin concesión S**. Comandos del modelo usan repositorio autónomo privado con índice/objetos/refs propios; importar resultados por operaciones tipadas del motor, no por un shell medio. |
| Git interno de mantenimiento | Operaciones tipadas y acotadas, binario fijado, sin hooks/fsmonitor/helpers arbitrarios del repo; si una operación carga código no confiable, se clasifica S. Nunca conceder toda `.git` exterior a un proceso del modelo por «lease específica». |
| MCP/Engram/LSP | Estado privado y stdio/pipes medidos, permisos de canal explícitos. Servidor incompatible no se vuelve E. Engram opcional puede usar respaldo disponible; no inventar éxito del servicio. |
| Terminal | Sesiones H y S separadas desde la autoridad de creación; `pty.write` automático no entra en H. Respaldo de pipes no abre una terminal ordinaria al agente. ConPTY se mide aparte. |
| Navegador/verificador | Código del entregable sigue S con perfil/log privados. Job y objetos internos de Chromium requieren prueba real; `--no-sandbox` actual no acredita aislamiento interno ni se elimina por conjetura. |
| GUI/preview | Apps del modelo en escritorio normal marcadas sin aislamiento de UI por decisión del propietario, sujetas a permisos realmente medidos. Preview compartido WebView2 no se incluye en cierre S como si recibiera token; separación P8. |
| WSL/Open Design | Acción H explícita; servicio/descendientes Linux no contenidos por encerrar `wsl.exe`. No ofrecer como salida automática S. |

La copia privada de entradas puede afectar imports y cwd. No se corrige concediendo write en instalación/runtime, perfil del propietario, repositorio compartido o canales privilegiados. H7 (rutas/servicios exteriores), H9 (semántica del guard de test) y H10 (hooks/versionado) conservan sus gates propios; SEC5 no los cierra por asociación.

## 10. Inventario de migración y cobertura

Inventario heredado del v1 y comprobado por el segundo auditor: **18 sitios directos de producción**, 2 indirectos WebView2, 2 acciones del instalador y 5 fixtures. Las categorías son destino de migración, **no controles hoy impuestos**. Las líneas son referencias de esa lectura, susceptibles de cambiar; P7 las actualizará desde código y repetirá búsqueda de primitivas. En esta corrida no se afirma otro rastreo completo ni un porcentaje S migrado.

| Sitio | Operación | Categoría/parte |
|---|---|---|
| `core/src/executor.zig:933` | `spawnWin32Pinned`, comandos/verificadores/sondas | S por defecto; E solo con permiso de perfil. P4. |
| `core/src/executor.zig:1207` | `createDetachedPinned` | S detached con propietario retenido; H tiene otra autoridad. P4. |
| `core/src/cli_worker.zig:228` | CLI headless | E únicamente perfiles exceptuados; resto S. P6. |
| `core/src/mcp_client.zig:576` | MCP/ACP/Engram stdio | S terceros, E ACP registrado, T propio fijado. P6. |
| `core/src/hooks.zig:267` | Hook configurado | S, entrada autorizada/versionada. P4. |
| `core/src/spaces.zig:147` | Git de mantenimiento | Operación acotada; no shell medio para modelo. P5. |
| `core/src/engine_process.zig:213` | Motor propio `--engine-pipe` | T; migración general P8. |
| `providers/src/github.zig:172` | `runCmdWin32`/gh | S sin excepción genérica. P5. |
| `providers/src/github.zig:349` | Captura Git/gh/helpers | S, metadata privada y quoting único. P5. |
| `shell/host/bridge.cpp:123` | `RunCapture`, Git/WSL | Git S o mantenimiento tipado; WSL manual H. P6. |
| `shell/host/core_client.cpp:445` | Core propio supervisado | T; P8. |
| `shell/host/engine_supervisor.cpp:171` | Engine propio suspendido | T; comprobar fallos Job/resume antes de reanudar. P8. |
| `shell/host/lsp_client.cpp:45` | LSP registrado | S. P6. |
| `shell/host/pty_manager.cpp:115` | Shell ConPTY | H/S separados por autoridad y canal de entrada. P6. |
| `shell/host/pty_manager.cpp:184` | Respaldo por pipes | Misma separación H/S. P6. |
| `shell/host/remote_controller.hpp:338` | Core remote serve | T; P8. |
| `shell/host/shell_policy.hpp:318` | URL vía ShellExecuteW | D/H, no salida automática S. P8. |
| `shell/host/shell_policy.hpp:341` | Explorer `/select,` | D/H tipado. P8. |

WebView2: `webview_host.cpp:1653` crea entorno y `:686` controlador; preview usa entorno compartido (`:1031`) y eliminación de bridge (`:1023`). Son creación indirecta del runtime, sin parámetro de token del nuevo lanzador. Instalador: `tools/installer.iss:62–63`, instalación de WebView2/bootstrap anteriores al motor.

Fixtures del inventario: `governed_tool_executor.zig:1864`, `headless_adapter.zig:2809`, `worktree_prepare.zig:1199`, `test_bridge_policy.cpp:47`, `test_document_manager.cpp:523`. No cuentan como excepciones funcionales del producto.

Entradas que deben transmitir contrato sin contarse como otro spawn: `browser_gate`, `worktree_prepare`, sondas `external_agents`, capturas `headless_adapter`, ACP, Engram, webhooks y reanudación de tarjetas en `c_api`. La fachada C futura usa estructuras versionadas y propietario opaco de la **misma implementación Zig** para host/providers; no carga obligatoriamente el DLL del core para arrancar el propio core ni duplica política en C++.

## 11. Corrida siguiente, estado de evidencia y trazabilidad

### 11.1 Ejecución prevista

**Los comandos siguientes no se ejecutaron y el paso `test-sec5-os` todavía no existe.** Es la interfaz exigida para la implementación siguiente, no una afirmación de que este documento deje P1 ejecutable. Antes de cada compilación comprobar bytes libres reales en C: **≥ 18 × 1024³**; si faltan, parar sin borrar cachés. Usar `pwsh` y el Zig de `tools/suite_evidence.ps1`. Caché: `las reglas del repositorio` pide una caché nueva por sesión, pero el prompt de continuidad del propietario del 8-oct (posterior) fija `%LOCALAPPDATA%\Temp\beats-cache-suite` con prefijo `%LOCALAPPDATA%\Temp\beats-dev-out-suite` como caché vigente del proyecto, y el disco no admite otra caché completa. El coordinador aplica esa regla posterior (decisión registrada tras la auditoría del segundo auditor del v2, hallazgo 1). Si el propietario la cambia, se sustituye por `%LOCALAPPDATA%\Temp\beats-cache-sec5-<sesión>`.

Una vez implementado el paso, desde este worktree y **fuera del sandbox de Codex**, con usuario estándar:

```powershell
& 'C:\devagents\toolchain\zig\zig.exe' build test-sec5-os -j1 --cache-dir "$env:LOCALAPPDATA\Temp\beats-cache-suite" --prefix "$env:LOCALAPPDATA\Temp\beats-dev-out-suite" --summary all
```

La corrida se captura con stdout/stderr completos y `EXIT_CODE` bajo `la documentación interna`, usando un wrapper de evidencia del worktree al implementar. Ese wrapper comprueba espacio antes del build y guarda comando, token representativo, bytes libres, versión del SO, binarios/hashes, casos/control, errores, conteos, skips, limpieza y código final. No resolver `test-sec5-os` mediante `tools/suite_evidence.ps1 -Target`, cuyo ValidateSet actual no lo acepta; el wrapper nuevo usará el comando anterior. No escribir logs artificiales como si fueran ejecuciones.

Después de P1 y de cada restauración de mutación: `zig fmt --check` de los `.zig` tocados; al final, suite global exacta:

```powershell
pwsh -NoProfile -File tools/suite_evidence.ps1 -Mode suite-loaded -Topic sec5-p1-full -EvidenceDirectory 'C:\devagents\sec-os\evidencia'
```

La suite también exige espacio antes de compilar. Guardar **todas** las salidas, rojas incluidas; por cada mutación conservar rojo, restauración de configuración/hashes y verde posterior. El constructor añadirá únicamente marca BUILD append-only con evidencia real, nunca AUDIT. No se escribirá BUILD PASS para una suite no ejecutada. Integración y commits pertenecen al coordinador.

### 11.2 Estado histórico de la corrida del 9-oct (sustituido por §11.5)

Continuidad del constructor del 9-oct, después del PASS CON CAMBIOS del segundo auditor. §11.1 conserva intacta la decisión de caché del coordinador; su párrafo inicial describe el estado anterior a esta escritura. El paso ahora está definido en fuente, pero su compilación y ejecución siguen pendientes.

| Elemento | Estado real |
|---|---|
| Diseño v2 | PASS CON CAMBIOS del segundo auditor; decisión de caché resuelta por el coordinador. No es auditoría de P1. |
| Derechos/etiquetado, token, CreateProcessAsUserW, Job y objetos de sesión | **NO VERIFICADO**; no ejecutados. |
| Cada SEC5 de §8.2/§8.3 | **NO VERIFICADO**; sin ruta de salida ni conteos medidos. |
| Cada mutación de §8.4 | **NO VERIFICADO**; no existe rojo ni verde de esta corrida. |
| Node/Python y transportes reales | **NO VERIFICADO**; ni siquiera se afirma aquí que estén instalados. |
| Formato Zig | `zig fmt --check` final ejecutado, **EXIT_CODE=0**: `sec5-format-20261009-232714-407-01.txt`. Rojo inicial de sintaxis conservado en `sec5-format-20261009-230352-109-01.txt`; corregido el campo C `error` con `@"error"`. El formato no acredita compilación. |
| Formato C | `clang-format --dry-run --Werror`, **EXIT_CODE=0**: `sec5-c-format-final-source-check-20261009.txt`. No compila ni comprueba semántica C. |
| Build focalizado y suite global | **NO EJECUTADOS**, disco insuficiente; conteos **null / NO MEDIDOS**. No se reutilizan resultados de otros lotes. |
| P1 y paso de build | Escritos: `governed_process.zig`, cabecera privada `sec5_launch.h`, entradas Zig padre/hijo y fixtures C; `test-sec5-os` independiente, sin conexión a `test`, core, DLL, host ni lanzamientos de producción. **SIN COMPILAR**. |
| Viabilidad técnica en usuario estándar | **NO VERIFICADA**; no confundir bloqueo operativo por disco con error 1314 o inviabilidad medida del mecanismo. |

El wrapper `tools/sec5_evidence.ps1` resuelve `ZIG_PATH` desde `suite_evidence.ps1`, usa la caché/prefijo de §11.1, mide `DriveInfo.TotalFreeSpace` (bytes físicos, sin cuota), captura stdout/stderr y `EXIT_CODE`, registra hashes de fuente/artefactos y ejecuta formato incluso si falta espacio. Su primer intento de consulta CIM recibió «Acceso denegado» bajo el sandbox; se sustituyó la dependencia de WMI por la consulta nativa de.NET. La invocación final de `-Mode all` midió **15.581.921.280 bytes libres** frente a **19.327.352.832 requeridos**; se detuvo con **EXIT_CODE=79** en `sec5-session-20261009-232714-407.txt`, después de formato y **antes de compilar**. No se compiló ni se borraron cachés. Las evidencias están bajo `la documentación interna`.

El padre nativo detecta token restringido, IL distinto de media o elevación, imprime los **28 nombres exactos de §8.2** como `ENVIRONMENT_NOT_REPRESENTATIVE` y devuelve no cero, sin modificar fixtures. En entorno representativo exige NTFS fijo en el volumen del sistema, `FILE_PERSISTENT_ACLS`, GUID/serial/FileId y reapertura de su nueva raíz por ID. Después mide ausencia y media explícita → baja → descriptor exacto; si falla, bloquea antes de lanzar S. Solo se preparan objetos nuevos de la prueba, con SACL explícitamente vacía o de etiqueta y protegida contra auditoría heredada desconocida; un rechazo de ese dominio también bloquea. El hijo privado se copia **solo por bytes**, recibe ACE de lectura/ejecución, se retiene contra escritura/borrado y el lanzador comprueba el FileId de la ruta que abrirá Windows. El nonce del caso READ nunca se entrega al hijo por stdin: debe obtenerlo del archivo exterior fixture. Python usa `-B -c` para evitar cachés de bytecode del control ordinario en la instalación. Esto es una entrada fixture; **no implementa ni acredita la autorización de entradas de producción de P3**.

Las mutaciones preparadas son parámetros privados del mismo binario, con aserciones intactas: `no-il`, `no-sid`, `no-write-restricted`, `breakaway-ok`, `no-handle-list`, `resume-first`. El wrapper exige FAIL del caso discriminante y resumen FAIL, conserva la salida roja, vuelve a `baseline`, exige verde y comprueba formato. Bloqueo por etiqueta, 1314, compilación o entorno no representativo no acredita una mutación roja. `resume-first` tiene barrera de primer acto y nieto real antes del fallo sembrado de asignación. Los brokers normal/crash conservan el único handle de Job; el padre verifica PID, tiempo, relación padre/hijo y muerte de descendientes. El journal, recuperación durable y exclusión S/E de P2 siguen **NO IMPLEMENTADOS / NO VERIFICADOS**.

Comando único para el coordinador, desde este worktree, fuera del sandbox, usuario estándar y **≥18 GiB**:

```powershell
pwsh -NoProfile -File tools/sec5_evidence.ps1 -Mode all
```

Ejecuta baseline, las seis parejas rojo/restauración/verde, formato y la suite global exacta de §11.1. `-Mode run` limita la corrida a P1; `-Mode format` no compila. Un bloqueo en baseline detiene las mutaciones; un rojo no demostrado o un verde fallido detiene el wrapper. No hay medición independiente de GUI, MCP real, ConPTY, crash recovery durable o S/E en esta continuidad.

Cuando P1 termine, actualizar esta sección y cada caso con resultado medido, entorno representativo/provisional, salida literal y ruta, positivos/negativos, mutaciones rojo/verde, números exactos de suite y veredicto «viable», «viable con condiciones» o «bloqueado» con motivo. No reemplazar NO VERIFICADO por inferencias de documentación. Un 1314 medido será «bloqueado»; una corrida bajo token restringido de Codex será provisional/no representativa y no decidirá viabilidad.

### 11.3 Correspondencia con los siete obligatorios del segundo auditor

«Resuelto en diseño» significa que existe contrato y gate explícitos. No significa implementación, BUILD PASS ni cierre por auditor.

| Obligatorio | Secciones que lo resuelven por escrito | Comprobación pendiente |
|---|---|---|
| 1. H3 y excepción E medible | §1 define perfiles, riesgo, literal de cabina y métricas de cobertura; §2 coloca procedencia antes del rollout | Persistencia/visibilidad E, ningún otro CLI exento y cierre S en P7. |
| 2. Entrada explícita retenida | §3 define `authorized_input`, handle, identidad, hash, estrategias, binding de argv y ciclo completo del árbol | Pin/ruta/mappings/snapshot, cambios de identidad/hash y tarjetas P3. |
| 3. Objetos de sesión / WinSta0 | §5 fija capacidades y diferencia existentes/nuevos; §8.2 exige observación y controles | Acceso real a evento/mutex/pipe/WinSta0/stdio en P1; MCP/LSP/ConPTY P6; UI P8. |
| 4. WRITE_OWNER / SeRelabelPrivilege / volúmenes | §6 separa derechos y privilegios, reversión, descriptor íntegro y lista de admisión | Roundtrip y permisos usuario estándar P1; gates por objeto/volumen P2. |
| 5. Exclusión, journal y snapshot con label | §7 especifica locks por identidad, DACL/squatting, registros previos, estados idempotentes y contrato de ampliación del snapshot existente | Crash matrix, identidad/cola parcial y S/E entre procesos P2. |
| 6. P1 sin GUI | §2 y §4 limitan P1; §5.2 delimita desktop/estación posterior y literal sin aislamiento de UI | Viabilidad básica P1 independiente; escritorio/GUI P8. |
| 7. Mutaciones separadas y pruebas faltantes | §8.2–§8.4 discriminan SID/WRITE_RESTRICTED y añaden sesión, herencia, crash/recovery y S/E | Rojos y verdes capturados; no hay mediciones en esta corrida. |

### 11.4 P1 ronda 2: correcciones estáticas, sin compilación

La auditoría estática del segundo auditor de P1 dio **FAIL**. Esta ronda corrige los nueve puntos del encargo; el propietario ordenó **no compilar**. Compilación, pruebas de SO, mutaciones rojo/verde, recuperación HKCU y viabilidad siguen **NO VERIFICADAS**. No se añade una fila BUILD ni se certifica cierre de auditoría. §11.1 y su decisión de caché/prefijo se conservan.

1. **Propiedad de procesos.** PID, parentesco y tiempo de creación sirven para observación, nunca para autorizar terminación. La pertenencia exige la lista de PIDs de `QueryInformationJobObject(JobObjectBasicProcessIdList)` y `IsProcessInJob` sobre el proceso abierto. El arnés termina sus Jobs o el handle exacto devuelto al crear su hijo. Los handles abiertos por PID solo se observan y cierran. Un descendiente vivo sin pertenencia demostrada hace fallar la limpieza, no se termina y se conserva la raíz. El hijo fixture conserva desde `CreateProcessW` el handle del nieto TREE/BREAKAWAY y lo termina al recibir liberación; el padre observa su muerte. Los controles ordinarios llevan un Job del arnés con BREAKAWAY_OK para conservar el control positivo de breakaway.
2. **Raíz por identidad.** El handle original incluye DELETE y permanece abierto sin compartir WRITE/DELETE hasta la disposición final. Cada directorio recorrido queda igualmente retenido. Los objetos se abren con FILE_FLAG_OPEN_REPARSE_POINT, se comprueban atributos y cualquier reparse point detiene la limpieza. Se comprueban volumen y FileId antes de recorrer y antes de cada borrado; `SetFileInformationByHandle(FileDispositionInfo)` borra el mismo objeto retenido. Discrepancia/error detiene el recorrido y deja la raíz para **revisión manual**, sin respaldo por nombre. El contrato de DELETE está en [Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfileinformationbyhandle).
3. **Omisiones.** Ninguna medición obligatoria omitida permite EXIT_CODE=0. Node/Python ausentes son FAIL por defecto. `-AllowMissingRuntimes` permite registrar SKIPPED explícito en el binario y en la evidencia, pero sigue bloqueando el gate y cualquier veredicto viable. SKIPPED no cuenta como medición completa. La prueba nueva eleva a 29 los nombres del arnés.
4. **Breakaway parental.** Antes de lanzar se capturan PID/tiempos de creación; después se toma un snapshot independiente. Se recorren los nuevos descendientes y se abre cada proceso para comprobar pertenencia al Job. La negativa exige medición completa y cero descendientes nuevos/fuera del Job. El paquete del hijo establece la barrera de intento y aporta información; su error no decide la negativa. El tiempo capturado antes distingue PID reutilizado; un error de observación bloquea y no se convierte en ausencia.
5. **Contención de resume-first.** El arnés crea un Job exterior no heredable, sin breakaway y con KILL_ON_JOB_CLOSE antes del lanzamiento mutado. Pasa su handle mediante la capacidad privada `harness_job`. El lanzador asigna el hijo suspendido al Job exterior antes de la rama que deliberadamente reanuda sin asignar al Job SEC5. El nieto queda fuera del Job SEC5, dentro del exterior; la limpieza termina/cierra ese Job y espera su contador de procesos activos a cero. La aserción original sigue haciendo rojo `SEC5 FAIL before resume no child` por marcador/reanudación temprana. La contención exterior no acredita corrección del Job SEC5.
6. **Cero handles.** STARTUPINFO con cb=sizeof(STARTUPINFOW), sin STARTF_USESTDHANDLES ni EXTENDED_STARTUPINFO_PRESENT, y bInheritHandles=FALSE. STARTUPINFOEX y su flag solo se usan con lista inicializada. El tamaño de HANDLE_LIST usa `@as(c.SIZE_T, r.handle_count)` explícito. `SEC5 HANDLE zero handles launch` lanza un hijo real que sale cero. La elección sigue la distinción de [CreateProcessAsUserW](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessasuserw).
7. **Token positivo.** En `SEC5 TOKEN effective child`, el padre consulta el token efectivo del hijo ordinario antes de liberarlo: integridad media, cero SIDs restrictivos e IsTokenRestricted=FALSE, además del control restringido existente.
8. **Wrapper.** Captura hashes SHA-256 de fuentes al inicio y los compara en el finally exterior, también ante bloqueo/formato/excepción. Diferencia o imposibilidad de comparar impone salida no cero. Cada mutación intenta siempre baseline restaurada en finally; rojo no demostrado se registra como fallo aunque el baseline posterior pase. El control de disco sigue antes de cada posible compilación, también durante restauración. No se borra ni cambia beats-cache-suite/beats-dev-out-suite (§11.1).
9. **HKCU huérfano.** Las claves nuevas llevan owner=sec5-fixture y owner_pid. Al preparar la siguiente corrida representativa se enumeran candidatas Software\DevAgents-SEC5-*; se leen solo esos valores y se borra una huérfana únicamente con marca exacta. Se preservan claves sin marca y fixtures cuyo propietario siga vivo o no pueda consultarse. No se accede a credenciales ni datos de DevAgents.

La salida de formato de esta ronda se captura en `sec5-r2-format-20261009.txt`: solo acredita `zig fmt --check` y `clang-format --dry-run --Werror`. Cuando haya ≥18 GiB, el comando del coordinador sigue siendo `pwsh -NoProfile -File tools/sec5_evidence.ps1 -Mode all`, fuera del sandbox y como usuario estándar. Añadir `-AllowMissingRuntimes` registra la excepción; si falta un runtime, la salida sigue siendo no cero.

### 11.5 P1 ronda 4: compilación y etiqueta dentro del sandbox

Estas salidas son provisionales; **no sustituyen las mediciones del coordinador fuera del sandbox**. El wrapper ahora fija `ZIG_GLOBAL_CACHE_DIR` bajo `beats-cache-suite/global`, como el wrapper de la suite. El intento anterior sin esa variable (`sec5-baseline-20261010-005613-652-02.txt`) falló por AccessDenied en la caché global fuera del sandbox.

- `sec5-baseline-20261010-005823-408-02.txt`: ambos ejecutables **compile success**, sin errores C/Zig; 24.543.621.120 bytes libres antes (≥18 GiB). Ausencia y media explícita restauran semánticamente; se registran diferencias SACL `0x0010` y `0x0800`. `SEC5 LABEL standard user roundtrip` y `SEC5 LABEL missing WRITE_OWNER blocks` pasan. La suite completa devuelve 78 (build/wrapper 1), **BLOCKED: 3 PASS, 10 FAIL, 0 SKIPPED**; no se certifica viabilidad.
- `sec5-baseline-20261010-005902-818-02.txt`: mutación `restore-auto-inherit`, **FAIL nominal** con DACL diff `0x0400`, etiqueta efectiva igual y SACL diff `0x0810`. Reparación local por kernel semánticamente exacta y `cleanup=1`. Preparación informa **1338**, no el 87 residual. Resumen BLOCKED; build/wrapper 1. Este rojo discrimina la DACL, no una denegación de API.
- `sec5-baseline-20261010-005958-130-02.txt`: baseline posterior con hashes de fuentes idénticos en `sec5-session-20261010-005958-130.txt`; ambos compilados en caché, roundtrip **PASS** otra vez y mismas diferencias SACL. Antes/después: 24.519.368.704 / 24.517.091.328 bytes libres. La suite completa sigue bloqueada; **no hay verde global restaurado**, y el wrapper `-Mode all` no puede acreditar las siete parejas hasta resolver la baseline fuera del sandbox.

Bloqueos posteriores medidos: `governed_process` devuelve **stage=4 (SEC5_POLICY), error=1314, pid=0**, y el control ordinario consulta **IL=4096**, aunque exige media. No se atribuyen automáticamente al sandbox ni al etiquetado corregido: el coordinador debe reproducirlos. Además, la terminación del target propio devuelve 5 y no se certifica árbol vacío; el fixture conserva la raíz para revisión manual. Estos casos no se presentan como «entorno no representativo» ni como pruebas verdes. Ningún lanzamiento de producción se modifica.

Raíces retenidas por los intentos del constructor: `.sec5-fixture-e501d121-9bb8-4e50-9891-6b18bc5e2bfa` (comparador inicial corregido), `.sec5-fixture-5987ba29-b593-45e9-be40-75c19977864e` y `.sec5-fixture-016fd571-6b8d-49cd-8502-7f6de9da81ad` (árbol no certificado vacío). No se borran automáticamente ni se toca `.sec5-fixture-946fead8-10da-4076-a4e6-3455b123826d`, que pertenece al coordinador. La mutación sí limpió su propia raíz. La suite global y auditoría independiente siguen pendientes.

Desde este worktree, fuera del sandbox, usuario estándar y ≥18 GiB:

```powershell
pwsh -NoProfile -File tools/sec5_evidence.ps1 -Mode all
```

## 12. Medición P1 en el equipo del propietario (coordinador, 10-oct, fuera del sandbox de Codex)

Usuario estándar real (IL media, sin elevar, sin modo desarrollador), Windows 11 Pro 26200, NTFS. Última línea base: `sec5-baseline-20261010-011120-031-02.txt`: **21 PASS, 6 FAIL, 2 observaciones; limpieza completa con descriptores exactos**. Veredicto P1: **viable con condiciones**; las condiciones y los residuos siguientes sustituyen a lo que §4–§6 daban por supuesto.

### 12.1 Lo que el diseño suponía y la medición corrigió

| Supuesto | Medido | Cambio aplicado | Evidencia |
|---|---|---|---|
| SACL protegida (`S:P`) para aislar la etiqueta de herencias de auditoría | Un usuario estándar no puede crear objetos con SACL protegida: **1314** (pide `SeSecurityPrivilege`) | SDDL de fixtures con `S:(ML;…)` sin `P` | `orq-sddl_probe-20261010.py`, `orq-label-medicion-20261010.txt` |
| Fijar `TokenMandatoryPolicy` en el token | Solo con `SeTcbPrivilege`: **1314** | Se **verifica** que el token ya tiene `NO_WRITE_UP` + `NEW_PROCESS_MIN` (es la política por defecto) | `governed_process.zig`, baseline |
| Restaurar etiqueta con `SetSecurityInfo` | Añade `AI` a DACL y SACL: nunca vuelve idéntico | `Get/SetKernelObjectSecurity` sobre el handle retenido; DACL idéntica; solo cambian `SE_SACL_PRESENT`/`SE_SACL_AUTO_INHERITED` (registrados, sin efecto en la integridad efectiva) | `orq-label_roundtrip-20261010.py` |
| Un ejecutable copiado en el destino preparado sirve para el control ordinario | Hereda la etiqueta **LW** del destino y, por `NEW_PROCESS_MIN`, arranca en IL baja también con token ordinario | Copia privada del hijo en la raíz del fixture, sin etiqueta | baseline (`ORDINARY_CHILD_TOKEN IL=8192`) |
| SIDs restrictivos = solo la lease | **Ningún binario que cargue user32 arranca** (`0xC0000142`, también `cmd`, `where`, `python`), ni añadiendo logon ni DACL por defecto | Restrictivos = **lease + Everyone + Users + Authenticated Users + RESTRICTED + logon**; DACL por defecto del token con **lease y RESTRICTED** | `orq-matriz-aislamiento-20261010.txt` |

### 12.2 Matriz de escritura medida (hijo Python real)

Con el token final (restrictivos ampliados + IL baja): **denegado** en archivos solo del usuario, en objetos medios escribibles por Users/Everyone y en objetos medios con ACE de lease; **permitido** en el destino preparado (IL baja + ACE de lease). Sin IL baja, los grupos genéricos abren los objetos medios escribibles por Users/Everyone: **la integridad baja es imprescindible** con este conjunto de SIDs. Residuo: un objeto de IL baja escribible por un grupo genérico es escribible por el hijo (otras órdenes no, porque usan SIDs de lease distintos).

### 12.3 Procesos del usuario (hallazgo de seguridad)

Contra un proceso ordinario con su DACL **por defecto** (`orq-procesos-medicion-20261010.txt`), el hijo aislado obtiene **`PROCESS_TERMINATE`** y `PROCESS_QUERY_LIMITED_INFORMATION`; se le deniegan `VM_WRITE|VM_OPERATION`, `CREATE_THREAD`, `SUSPEND_RESUME` y `DUP_HANDLE`. `TERMINATE` no se mapea a escritura, así que ni `WRITE_RESTRICTED` ni MIC (`NW`, ni siquiera `NWNR` en el proceso) lo bloquean. **El código del modelo aislado puede matar procesos del usuario; no puede inyectarles código.** Decisión pendiente del propietario (ver relevo): aceptarlo como residuo declarado, o pasar a un token totalmente restringido / AppContainer (ADR aparte).

### 12.4 Fallos restantes de la línea base (de fixture, no de mecanismo)

1. `SEC5 PROCESS TERMINATE denied`: espera denegación; la medición de §12.3 dice que **no** se deniega. Además el fixture pone al objetivo una DACL propia con ACE de lease `0x1201ff` (máscara de archivos: en un proceso incluye `TERMINATE`). Rehacer con la DACL por defecto y convertirla en prueba del residuo declarado si el propietario lo acepta.
2. `SEC5 SESSION named pipe observed`, `SEC5 SESSION default DACL measured`, `SEC5 SESSION WinSta0 access observed`: el control o el registro de la observación quedan incompletos (`connect_error=535` es `ERROR_PIPE_CONNECTED`, que es éxito).
3. `SEC5 JOB breakaway denied`: el hijo recibe 5 al pedir breakaway (correcto) pero el fixture no lo cuenta (`actual_grandchild=0`).
4. `SEC5 JOB normal grandchild contained`: el nieto está en el Job exacto (`member_exact_job=1`) y aun así falla la condición.

Mutaciones y suite global: **no ejecutadas todavía** sobre esta versión.

### 12.5 Ronda 5

La línea base del coordinador `sec5-baseline-20261010-053556-045-02.txt`, fuera del sandbox, registra **21 PASS, 6 FAIL y 2 observaciones**, `exact_label_restore=1` y `cleanup=1`. Sus trazas establecen cuatro hechos:

1. **Pipe desconectado.** El control escribe los 16 bytes correctos, pero `DisconnectNamedPipe` deja la instancia desconectada. El intento aislado recibe 5 y no mide una instancia a la escucha. El fixture ahora exige `ConnectNamedPipe` → `ERROR_PIPE_LISTENING` antes del intento aislado y después de la denegación; registra resultado y código real en ambas comprobaciones.
2. **Identificación de WinSta0.** Ambos hijos abren `WINSTA_READATTRIBUTES` y `WINSTA_ACCESSCLIPBOARD`; consultar `UOI_NAME` con el segundo handle falla con 5 porque no tiene READATTRIBUTES. Ahora cada copia conserva exactamente sus derechos y se identifica con `CompareObjectHandles` contra WinSta0 abierto por el padre. Se observa también ACCESSCLIPBOARD, sin usar el portapapeles ni ampliar derechos.
3. **Descendientes de consola.** Breakaway aislado deja un `conhost.exe` dentro del Job; el nieto normal deja dos `conhost.exe` y un `sec5-child.exe`, todos miembros. Ahora una consola solo se reconoce mediante `QueryFullProcessImageNameW` y comparación de la ruta completa normalizada con `%SystemRoot%\System32\conhost.exe`. `outside` incluye todos los descendientes vivos, también consolas. Breakaway exige cero otros y denegación 5; el nieto normal exige un único otro, identificado por PID y hora de creación y miembro del Job. Se conservan `image=` y los recuentos `consoles=`/`others=`.
4. **DACL heredada de objetos con nombre.** La sonda `orq-bno_default_dacl-20261010.py` y la misma corrida muestran que un evento `Local\` creado con SD NULL hereda la DACL del directorio de sesión: SYSTEM, usuario y logon (`0x1f0003`), con etiqueta `S:(ML;;NW;;;LW)` por su creador de IL baja. No aplica la TokenDefaultDacl con lease y RESTRICTED. `SEC5 SESSION child named object cross-lease observed` registra la SDDL completa, `token_default_applied=0/1`, control ordinario y resultado real de una segunda lease. Conserva el endurecimiento de la copia privada del ejecutable y exige su restauración exacta.

También se implementa la observación de §12.3, respaldada por `orq-procesos-medicion-20261010.txt`: `SEC5 PROCESS TERMINATE user process observed` conserva la DACL por defecto del objetivo. El control ordinario exige muerte con código 37; el aislado registra OBSERVED_ALLOWED solo con ese efecto o OBSERVED_DENIED con código Win32 y objetivo vivo. VM_WRITE conserva su descriptor y comprobaciones existentes. La decisión sobre TERMINATE sigue pendiente del propietario.

**Residuo candidato: objetos con nombre entre órdenes aisladas con leases distintas — pendiente de medir por el coordinador.** La DACL heredada permite como hipótesis el chequeo normal por usuario y el restringido por logon, con LW frente a LW; el fixture registra el efecto real sin anticipar permitido ni denegado.

El resultado esperado para la nueva línea base es **23 PASS, 0 FAIL y 6 observaciones completas** (evento, mutex, pipe, WinSta0, TERMINATE y objeto con nombre), total 29 nombres. Una observación incompleta es FAIL; ninguna observación suma PASS. Limpieza y omisiones bloquean el veredicto sin añadir resultados nominales ficticios. La mutación resume-first mantiene su alcance deliberado de un nombre.

Revisión de `tools/sec5_evidence.ps1 -Mode mutations`: ninguna de sus siete mutaciones depende de TERMINATE ni de la antigua prueba default DACL; **no se reasigna ni debilita ninguna**. Se mantienen los blancos PASS/FAIL: `no-il` → MIC medium write, `no-sid` → SID foreign low write, `no-write-restricted` → READ ordinary readable outside, `breakaway-ok` → JOB breakaway, `no-handle-list` → HANDLE excluded, `resume-first` → FAIL before resume, `restore-auto-inherit` → LABEL standard user roundtrip. Sus rojos y verdes siguen pendientes fuera del sandbox.

Comando del coordinador desde este worktree, usuario estándar, fuera del sandbox y **≥15 GiB libres**:

```powershell
pwsh -NoProfile -File tools/sec5_evidence.ps1 -Mode all
```

Incluye línea base, las siete mutaciones con restauración y la suite global. Las ejecuciones del constructor en el sandbox son **no representativas** y no certifican C2 ni C3.

Compilación del constructor: `sec5-r5-sandbox-compile-20261010-054819-049.txt`, ambos ejecutables con `-Wall -Wextra -Werror`, **EXIT_CODE=0**, y formato C 0. El intento mediante el grafo `test-sec5-os` también compila ambos; su paso run recibe deliberadamente un argumento inválido y devuelve 2 antes de preparar fixtures (build 1), sin mediciones de seguridad ni limpieza de fixtures ajenos. La primera compilación detectó el import ausente de CompareObjectHandles; se resuelve ahora esa API por GetProcAddress desde KernelBase.dll, su [DLL documentada por Microsoft](https://learn.microsoft.com/en-us/windows/win32/api/handleapi/nf-handleapi-compareobjecthandles), siguiendo el patrón existente del fixture y con fallo explícito si falta. No se toca Zig. Caché nueva del constructor conservada: `%LOCALAPPDATA%\Temp\beats-cache-suite\sec5-r5-20261010-054438-570`; disco antes/después de las compilaciones: 19.538.927.616 / 19.312.635.904 bytes (≥15 GiB). El wrapper de la suite global conserva su propio mínimo de 18 GiB; para medir solo C1–C3 se puede usar `-Mode mutations` (incluye baseline y siete parejas) con el mínimo P1 de 15 GiB.


## 13. Diseño v3 (AppContainer)

Fecha: 2026-10-10. Autor: Sol. **Diseño documental, sin implementación P1 v3 ni ejecución de su sonda.** La decisión 4 del propietario y [ADR-B009](adr/ADR-B009-aislamiento-appcontainer.md) fijan AppContainer como mecanismo principal. Esta sección sustituye las propuestas v2 de token/identidad, lectura ambiental y preparación obligatoria de etiquetas para el camino AppContainer. §1–§12 se conservan como historial y contrato del respaldo; las garantías de autoridad, procedencia, identidad, handles, Job, exclusión S/E y recuperación siguen aplicando.

### 13.1 Base medida y frontera

La línea base ronda 5 acredita **23 PASS, 0 FAIL, 6 observaciones, 29 nombres** para el token restringido. TERMINATE, evento creado por el hijo señalable desde otra lease, mutex y WinSta0/ACCESSCLIPBOARD están permitidos. La sonda de DACL confirma herencia del directorio de sesión, no de TokenDefaultDacl.

La sonda AppContainer y su salida acreditan denegación 5 de TERMINATE, QUERY_LIMITED y evento del usuario; evento propio invisible al usuario por el mismo nombre (2); escritura concedida OK, perfil del usuario denegado 5 y lectura System32 OK. Ese resultado **no mide todavía otra orden AppContainer**, registry, red, WinSta0, portapapeles ni los runtimes con capacidad.

P1 v3 sigue siendo fixture-only, sin GUI ni migración a producción. No promete confidencialidad integral: un AppContainer convencional conserva lecturas ambientales de recursos concedidos a ALL APPLICATION PACKAGES. La excepción E, la tarjeta por hash y la separación de UI de las decisiones 1–3 se mantienen.

### 13.2 Identidad, perfil y recuperación de huérfanos

**Unidad elegida: un perfil por lease de una sola orden.** El moniker será `DevAgents.Sec5.` seguido de 128 bits aleatorios en hexadecimal, dentro de los 64 caracteres admitidos. El nombre/SID no son secretos. Los procesos y nietos de esa lease comparten perfil; dos órdenes, aunque usen el mismo runtime, reciben monikers/SIDs distintos. Tras cierre, cancelación o reinicio recuperado, una nueva lease usa otro perfil; no se reutiliza un perfil viejo para ahorrar trabajo.

Secuencia del broker, sin incorporar nuevas tablas de producción en P1:

1. Verificar padre estándar representativo (§4.1), autoridad, entrada retenida/hash, raíces por identidad, exclusión y ausencia de journal pendiente. Registrar duraderamente intención, moniker, orden/lease, usuario propietario y plan de recuperación **antes** de `CreateAppContainerProfile`.
2. Crear perfil sin capacidades de red; registrar SID de paquete, ruta obtenida con `GetAppContainerFolderPath`, identidades y estado PROFILE_CREATED. Una colisión/already-exists bloquea; no adoptar ni borrar un perfil ajeno. Para recovery se deriva el SID del moniker registrado y se contrasta con el journal.
3. Preparar destinos y temporales con ese SID; registrar originales y concesiones antes de aplicarlas, leer de vuelta. Construir `SECURITY_CAPABILITIES` con el mismo SID y solo la capacidad de runtime autorizada. Perfil creado no demuestra token efectivo: consultarlo en el hijo suspendido.
4. Crear/asignar/verificar Job y reanudar solo con toda la preparación comprobada (§13.4). Mantener perfil, lease y pins durante **todo** el árbol, también detached.
5. Al terminar/cancelar: cerrar o terminar Job propio y acreditar árbol vacío; cerrar handles de almacenamiento del perfil. Reconciliar artefactos nuevos y restaurar descriptores externos por identidad (§6–§7); retirar ACE del paquete de todos los objetos conservados. Borrar temporales propios y llamar `DeleteAppContainerProfile`. Comprobar HRESULT, desaparición del almacenamiento conocido y registro de cierre; solo entonces liberar reserva.
6. Tras fallo: el recuperador procesa únicamente monikers con intención durable autenticada en el catálogo del broker. Cubre crash después de crear perfil pero antes de guardar su ACK/SID, después de cada concesión y después de árbol vacío. No reutiliza PID sin hora de creación ni presupone que borrar un perfil mata procesos. Si no puede acreditar árbol vacío, identidad o restauración, queda RECOVERY_BLOCKED; la raíz/perfil afectados no se reutilizan.
7. La limpieza es idempotente y admite un segundo intento: Microsoft documenta éxito al borrar perfil inexistente y estado indeterminado cuando el borrado falla. Conservar journal y reintentar explícitamente; no barrer `Packages` por prefijo o antigüedad, ni borrar perfiles que no consten como propios. Medir también un fallo de borrado por handle propio retenido y su recuperación.

La creación/arranque y rutas privadas están documentados en [Microsoft: lanzamiento](https://learn.microsoft.com/en-us/windows/win32/secauthz/implementing-an-appcontainer); el cierre de handles y reintento de borrado en [DeleteAppContainerProfile](https://learn.microsoft.com/en-us/windows/win32/api/userenv/nf-userenv-deleteappcontainerprofile). Borrar el perfil no retira una ACE aplicada a una carpeta exterior.

### 13.3 Carpetas, temporales y concesión única de runtimes

| Recurso | Identidad / concesión | Ciclo de vida |
|---|---|---|
| Destino preparado de la orden | Raíz NTFS admitida retenida, inventario sin reparse/hardlinks; permisos ordinarios del broker y ACE del **SID de paquete de esa lease** para datos, crear hijos y borrado autorizado. Sin WRITE_DAC/WRITE_OWNER/ACCESS_SYSTEM_SECURITY; sin borrado de raíz de control. | Snapshot/intención antes de setters; restaurar tras árbol vacío. Objetos nuevos requieren descriptor de publicación sin SID de paquete. |
| Temporales y cachés | Directorio propio de la lease con el mismo SID; `TEMP`, `TMP` y cachés de herramientas apuntan allí. El perfil aporta además almacenamiento privado del SO; se enumera como superficie autorizada. | Sin compartir con otra orden. Retirar después del árbol; perfil huérfano queda en journal. |
| Scripts/snapshot de entrada y ejecutable fijado | Solo RX/lectura al SID de paquete necesario; copia privada o pins de §3. No escribir ejecutables/runtimes desde S. | Retenidos hasta árbol vacío, con identidad/hash/cadena de shims verificadas. |
| Runtime instalado | **Solo RX** a `CapabilitySids[0]` derivado de `devAgentsRuntime`; no usar `CapabilityGroupSids`. Capacidad común no se aplica a destinos/temporales/IPC. | Concesión única por instalación/version física aprobada; backup y reversión. Cambio de versión/ruta/dependencias obliga a revalidar. |

AppContainer no necesita reproducir los SIDs restrictivos sintéticos de ronda 5. Tampoco se da por necesaria una etiqueta baja en todas las carpetas concedidas: la sonda AppContainer escribió con concesión del paquete sin bajar la etiqueta de la carpeta. **En v3 la autorización exterior depende del paquete/capacidad y derechos concedidos; no se promete que MIC bloquee una carpeta concedida expresamente.** Registrar etiquetas reales y no modificar las de runtimes. Las sondas de etiqueta de v2 se conservan separadas para el respaldo.

RX se limita a la instalación física inventariada: EXE, DLLs y módulos necesarios. No conceder sobre `C:\`, el perfil, padres globales, ALL APPLICATION PACKAGES ni el alias de NVM. `C:\nvm4w\nodejs` debe resolverse y fijarse por el coordinador; si es junction/symlink, se opera sobre la raíz física identificada, sin seguirlo al modificar ACL. No se conoce aquí esa ruta física y no se inventa.

**Aprobación pendiente:** el propietario aprueba runtime/version, SID medido, objetos afectados y backup antes de modificar instalaciones reales. La sonda usa exclusivamente copias privadas. Conceder RX es reversible sobre el mismo inventario; no se baja label ni se cambian owner/SACL.

**Comandos exactos propuestos, no ejecutados.** Las tres variables son entradas: `$Runtime` = raíz física certificada (por ejemplo `C:\Python314` una vez comprobada), `$CapabilitySid` = SID numérico emitido por la sonda para `devAgentsRuntime`, `$AclBackup` = ruta absoluta nueva en almacenamiento privado del broker, fuera del runtime. No se usa un SID inventado ni un comando de producto aún inexistente.

```powershell
# Ejecutar una vez por instalacion, despues de aprobar el inventario completo.
$runtimeItem = Get-Item -LiteralPath $Runtime -ErrorAction Stop
if (-not $runtimeItem.PSIsContainer -or
    ($runtimeItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Runtime debe ser una carpeta fisica certificada'
}
$runtimeRoot = $runtimeItem.FullName.TrimEnd('\')
$runtimeParent = [IO.Path]::GetDirectoryName($runtimeRoot)
$runtimeLeaf = [IO.Path]::GetFileName($runtimeRoot)
if ($CapabilitySid -notmatch '^S-1-15-3-[0-9-]+$') { throw 'SID de capacidad invalido' }
$backupPath = [IO.Path]::GetFullPath($AclBackup)
if (Test-Path -LiteralPath $backupPath) { throw 'Backup ya existe; no sobrescribir' }
if ($backupPath.StartsWith($runtimeRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Backup debe estar fuera del runtime'
}
Push-Location -LiteralPath $runtimeParent
try {
    & icacls.exe $runtimeLeaf /save $backupPath /T /Q
    if ($LASTEXITCODE -ne 0) { throw 'Snapshot DACL incompleto; no conceder' }
    & icacls.exe $runtimeLeaf /grant "*${CapabilitySid}:(OI)(CI)(RX)" /T /Q
    if ($LASTEXITCODE -ne 0) {
        & icacls.exe $runtimeParent /restore $backupPath /Q
        if ($LASTEXITCODE -ne 0) { throw 'Concesion parcial y rollback fallido; bloquear runtime' }
        throw 'Concesion fallida; DACL restauradas'
    }
} finally {
    Pop-Location
}
```

Reversión exacta propuesta sobre **las mismas identidades, sin actualizar el runtime entre medias**:

```powershell
& icacls.exe $runtimeParent /restore $backupPath /Q
if ($LASTEXITCODE -ne 0) { throw 'Restauracion incompleta; runtime bloqueado' }
```

`/T` alcanza descendientes protegidos del inventario; no se emplea `/C` para continuar ante errores ni `/reset` como falsa restauración. El inventario previo debe rechazar links en todo el árbol y fijar identidades contra sustitución; estos comandos por nombres son una operación administrativa controlada, no el mecanismo de recuperación de leases. El broker conserva referencias del backup y verifica DACL/control por objeto; `icacls /save` solo guarda DACL, no prueba captura de OWNER/SACL. La reversión posterior a cambios concurrentes se bloquea y reconcilia, no pisa nuevas ACL ciegamente. [Contrato de icacls](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/icacls).

La capacidad común no autentica al producto: otro lanzador autorizado por Windows puede derivar el mismo nombre. El riesgo aceptable propuesto es RX de runtimes, nunca escritura ni datos de órdenes. No empaquetar Node/Python; usar las instalaciones del propietario tras aprobación.

### 13.4 Lanzamiento, Job, stdio y handles

1. `STARTUPINFOEXW` conserva `PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES` incluso con **cero handles**. Construir atributos, SID y arrays con vida útil hasta destruir la lista. `CreateProcessW` lleva `lpApplicationName` absoluto fijado, argv escapado, entorno UTF-16 filtrado y flags `EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED`; P1 consola usa `CREATE_NO_WINDOW`.
2. Con stdio: pipes anónimos, extremos del padre no heredables, duplicados del hijo con dirección/derechos exactos. `STARTF_USESTDHANDLES` incluye stdin válido (pipe con EOF si no hay entrada); stdout/stderr separados en el fixture completo. Lista exacta en `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`, `bInheritHandles=TRUE`. Sin stdio ni otros handles: `bInheritHandles=FALSE`, sin HANDLE_LIST ni STARTF_USESTDHANDLES, pero sí atributos AppContainer.
3. El Job tiene `KILL_ON_JOB_CLOSE`, sin BREAKAWAY_OK/SILENT_BREAKAWAY_OK; handle único del broker no heredable. Asignar y comprobar pertenencia al Job **antes** de reanudar. Jobs exteriores compatibles se miden; fallo de asignación no se arregla activando breakaway.
4. Antes de Resume: consultar token efectivo: `TokenIsAppContainer=1`, SID de paquete exacto, capacidades concedidas, IL, UIAccess, virtualización y privilegios. Verificar Job y preparación/registro durable. No sustituir consultas por los flags solicitados.
5. Fallo antes de Resume: terminar/esperar al hijo suspendido aunque no haya podido asignarse al Job; registrar error primario y limpieza. Timeout/cancelación cierran el árbol, no solo el proceso principal. Draining de stdout tiene deadline y límite; no esperar con ReadFile bloqueante antes del timeout.
6. Ningún handle de proceso del usuario, Job, journal, raíz de control, token o WinSta0 se entrega a S. AppContainer no revoca derechos de un handle heredado. No compartir handles o endpoints entre órdenes por la capacidad RX.
7. Para objetos autorizados, usar preferentemente handles exactos. Un objeto con nombre propio se localiza en el namespace del paquete; el padre puede inspeccionarlo con namespace resuelto desde el token, sin otorgar acceso global. Los pipes con nombre requieren receta específica medida; el mismo string `Local\` no demuestra que un pipe esté aislado.

Los atributos de seguridad/handles y la vida útil de sus valores están documentados en [UpdateProcThreadAttribute](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute). El caso de cero handles de v2 no se copia con STARTUPINFO simple: perdería AppContainer.

### 13.5 Registro, red, WinSta0 y excepciones

- **Registro/HKCU:** no conceder escritura a HKCU ordinario ni pasar handles de claves del usuario. Una clave del padre propia de fixture con nonce debe quedar intacta; crear/escribir solo en almacenamiento del perfil devuelto por `GetAppContainerRegistryLocation` y verificarlo desde el padre. No asumir que cualquier `HKCU\Software` se redirige: registrar destino real, errores y ausencia de escrituras en el fixture externo. Lecturas ambientales se caracterizan; no se habilita registryRead como parche de AppContainer convencional. [API del almacenamiento privado](https://learn.microsoft.com/en-us/windows/win32/api/userenv/nf-userenv-getappcontainerregistrylocation).
- **Red:** cero `internetClient`, `internetClientServer` o `privateNetworkClientServer` por defecto; ningún loopback exemption ni socket ya abierto heredado. Medir conexión exterior, LAN y loopback frente a endpoints de prueba controlados con positivos ordinarios. Una decisión futura de red debe enumerar capacidades, destino y riesgo; no se agrega automáticamente para npm/pip/MCP. Las llamadas de proveedores permanecen en el broker de confianza, sin convertir stdio en proxy arbitrario.
- **Portapapeles/WinSta0:** no modificar DACL, no heredar esos handles ni prometer escritorio privado en P1. Registrar por separado READATTRIBUTES y ACCESSCLIPBOARD, comparación contra WinSta0 del padre y errores reales; apertura no equivale a lectura/escritura de clipboard. Este pertenece a la estación de ventanas. No leer ni alterar el clipboard del propietario: el ensayo de contenido requiere sesión de prueba/estación propia y consentimiento específico del operador. Si se permite acceso, queda observación y etiqueta «sin aislamiento de UI», conforme a decisión 2; no se presenta como aislamiento integral. [Window stations](https://learn.microsoft.com/en-us/windows/win32/winstation/window-stations), [OpenClipboard](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-openclipboard).
- **CLIs E:** exclusivamente Codex, Claude Code y OpenCode por ACP conservan excepción registrada y texto **«CLI externo sin aislamiento de DevAgents»**, según decisión 1. No reciben AppContainer por esta propuesta; su árbol interno está fuera de la garantía. Otros CLIs, MCP/LSP o una aprobación de script no heredan E.
- **Respaldo restringido:** conservar binarios/pruebas de ronda 5 y declarar TERMINATE/cross-lease/mutex/WinSta0 permitidos. Se usa en medición comparativa y, si el propietario lo habilita, para una ejecución explícitamente autorizada con advertencia y registro de perfil/riesgo. AppContainer fallido no se reintenta automáticamente con ese token ni con token ordinario. No cumple los criterios v3 ni cierra H3; mientras no se apruebe ese alcance queda fuera de lanzamientos S de producción.

### 13.6 Matriz P1 v3: los 31 nombres actuales

Fuente de nombres: `tests/sec5_fixture.c:99-130`, tabla `names`: 29 nombres heredados de la línea base ronda 5 y dos adicionales de C1.2. **Histórico anterior a ronda 1:** todos los resultados v3 estaban NO VERIFICADOS. **Medición del 13-oct-2026:** `la documentación interna` acredita AppContainer **17/17 PASS**, 0 FAIL, 0 omitidos y limpieza correcta; los otros 14 nombres quedan NO VERIFICADOS en ese backend por estar fuera del alcance de ronda 1. La última columna recoge esa medición, sin trasladar verdes del respaldo restringido a v3. Se preservan los nombres exactos aunque dos terminen en «observed»: su veredicto v3 cambia a PASS/FAIL obligatorio. PASS solo tras control ordinario representativo, barrera de intento y efecto verificado por el padre; denegación puede ser 5 o invisibilidad 2 para nombre en otro namespace, con objeto probado vivo. No confundir fallo de arranque con intento denegado.

«Exigido» significa PASS si se cumple el criterio, **FAIL bloqueante** si no. «Observación» exige medición completa y efecto/error; no suma PASS. Un canal observado que permita inducir escritura exterior bloquea su habilitación hasta resolver el intermediario. Los cambios de fixture indicados eran trabajo futuro en el diseño histórico; los implementados y medidos en ronda 1 se identifican abajo. Los restantes siguen pendientes; en este encargo no se edita tests/tools.

| # | Nombre exacto actual | Veredicto v3 / expectativa | Medición AppContainer ronda 1 |
|---|---|---|---|
| 1 | SEC5 ENV parent representative | **Exigido:** padre estándar medio, no elevado/restringido/AppContainer, sin impersonación contaminante. Otro entorno: ENVIRONMENT_NOT_REPRESENTATIVE y gate bloqueado. | **PASS** |
| 2 | SEC5 TOKEN effective child | **Exigido:** token suspendido AppContainer, SID de paquete correcto y capacidades exactas; IL bajo, sin privilegios peligrosos/UIAccess; Job acreditado. No exigir los seis SIDs sintéticos v2. | **PASS** |
| 3 | SEC5 MIC medium write denied | **Observación:** caracterizar carpeta media con concesión explícita al paquete frente a la misma sin concesión. Registrar permisos/label y escritura real. AppContainer no promete rechazo MIC de un recurso autorizado; no usar la ausencia de ACE de paquete como demostración de MIC. | **NO VERIFICADO**, fuera del alcance R1 |
| 4 | SEC5 SID foreign low write denied | **Exigido:** carpeta baja de otra lease/SID, sin ACE de este paquete ni capacidad compartida de datos; escritura denegada, nonce intacto. | **NO VERIFICADO**, fuera del alcance R1 |
| 5 | SEC5 DEST prepared write allowed | **Exigido:** crear/escribir bytes exactos en destino concedido al paquete; root/control exterior intactos. No precisa etiqueta baja añadida por el broker. | **PASS** |
| 6 | SEC5 READ ordinary readable outside | **Exigido:** **denegación** de lectura del fixture privado solo del usuario, sin ACE de paquete/capacidad/AAP. El nonce no sale por stdout. Se invierte la expectativa de WRITE_RESTRICTED; la positiva System32 va en prueba nueva. | **PASS** |
| 7 | SEC5 REG HKCU write denied | **Exigido:** clave ordinaria propia del padre no modificada, intento confirmado; sin handle heredado ni concesión al paquete. Separar almacén privado del perfil. | **NO VERIFICADO**, fuera del alcance R1 |
| 8 | SEC5 PROCESS VM_WRITE denied | **Exigido:** VM_WRITE y VM_WRITE\|VM_OPERATION denegados sobre objetivo ordinario propio; memoria nonce intacta. | **PASS** |
| 9 | SEC5 PROCESS TERMINATE user process observed | **Exigido: DENEGACIÓN** de PROCESS_TERMINATE; objetivo con DACL por defecto sigue vivo. Control ordinario termina otro objetivo propio con código 37. OBSERVED_ALLOWED ahora es FAIL. | **PASS** |
| 10 | SEC5 SESSION event observed | **Exigido:** evento del usuario sin concesión al paquete no señalable; control ordinario lo señala, S no cambia estado. | **NO VERIFICADO**, fuera del alcance R1 |
| 11 | SEC5 SESSION mutex observed | **Exigido:** mutex ordinario sin concesión al paquete no adquirible/modificable desde S; padre comprueba handshake y ausencia de interferencia. | **NO VERIFICADO**, fuera del alcance R1 |
| 12 | SEC5 SESSION named pipe observed | **Observación:** pipe ordinario propio a la escucha; intento, error, conexión y bytes de cliente reales. No inferir aislamiento de pipes del namespace de eventos. Acceso que provoque efectos exteriores impide habilitar ese transporte. | **NO VERIFICADO**, fuera del alcance R1 |
| 13 | SEC5 SESSION authorized objects allowed | **Exigido:** evento/endpoint propio autorizado funciona mediante handle exacto o receta de namespace/SD acreditada. El padre verifica señal/nonce; sin cambiar ACL de canales ordinarios para obtener verde. | **NO VERIFICADO**, fuera del alcance R1 |
| 14 | SEC5 SESSION child named object cross-lease observed | **Exigido: DENEGACIÓN** desde otra lease en **otro AppContainer**, ambos vivos y capaces de usar su evento propio. A crea con SD NULL; B no abre/señala el objeto de A ni por nombre relativo ni por ruta de namespace conocida. Descriptor y señal medidos por el padre. | **PASS** |
| 15 | SEC5 SESSION WinSta0 access observed | **Observación:** READATTRIBUTES y ACCESSCLIPBOARD separados y comparados contra WinSta0 del padre; no consumir clipboard. No prometer DENIED sin medición ni declarar aislamiento de UI. | **NO VERIFICADO**, fuera del alcance R1 |
| 16 | SEC5 STDIO anonymous allowed | **Exigido:** stdin nonce, stdout y stderr exactos/separados, EOF y salida sin hang mediante HANDLE_LIST. | **PASS** |
| 17 | SEC5 JOB breakaway denied | **Exigido:** CREATE_BREAKAWAY_FROM_JOB no produce descendiente fuera del Job; registrar todos, incluidas consolas, por identidad. | **PASS** |
| 18 | SEC5 JOB normal grandchild contained | **Exigido:** nieto real en Job exacto **y mismo AppContainer**, token consultado por padre; no basta que el spawn sea denegado. | **PASS** |
| 19 | SEC5 JOB nested contained | **Exigido:** Job exterior fixture compatible y Job SEC5 contienen hijo/nieto; ningún flag de escape. | **PASS** |
| 20 | SEC5 JOB broker close kills tree | **Exigido:** único handle Job del broker; cierre normal y crash matan hijo/nieto verificados por PID+creación; padre sin copia del Job. | **PASS** |
| 21 | SEC5 HANDLE excluded not inherited | **Exigido:** handle extra inheritable excluido no permite señalizar su objeto; testigo autorizado funciona. No probar solo el número de handle. | **PASS** |
| 22 | SEC5 FAIL before resume no child | **Exigido:** fallo sembrado de token/ACL/Job/journal antes de Resume; ningún primer acto ni proceso vivo; limpieza y error primario explícitos. | **PASS** |
| 23 | SEC5 LABEL standard user roundtrip | **Exigido, diagnóstico heredado del respaldo:** mismo roundtrip semántico de §6.2 sobre fixture propio; no obliga a relabel de destinos AppContainer. | **NO VERIFICADO**, fuera del alcance R1 |
| 24 | SEC5 LABEL missing WRITE_OWNER blocks | **Exigido, diagnóstico heredado:** setter LABEL sin WRITE_OWNER falla y SD queda intacto. No confundir con la preparación AppContainer mediante WRITE_DAC, que no exige relabel. | **NO VERIFICADO**, fuera del alcance R1 |
| 25 | SEC5 LABEL inheritance measured | **Observación:** labels reales de raíz y fichero/subdirectorio nuevo, flags y DACL de paquete; objeto protegido preexistente intacto. No imponer LW recursivo como requisito nuevo. | **NO VERIFICADO**, fuera del alcance R1 |
| 26 | SEC5 SECURITY child cannot widen | **Exigido:** sobre destino preparado no amplía DACL/owner/label ni concede otra lease; padre compara SD y controla con token ordinario. Medir OWNER RIGHTS cuando proceda. | **NO VERIFICADO**, fuera del alcance R1 |
| 27 | SEC5 NODE inline compatible | **Exigido:** Node fijado, RX por devAgentsRuntime autorizado; inline crea nonce en destino y no altera exterior. En este equipo existe; ausencia en otros equipos es SKIPPED bloqueante de esa compatibilidad, no PASS. | **NO VERIFICADO**, fuera del alcance R1 |
| 28 | SEC5 PYTHON inline compatible | **Exigido:** Python fijado con DLL/imports necesarios y capacidad RX; mismos efectos medidos, cachés internas confinadas. | **NO VERIFICADO**, fuera del alcance R1 |
| 29 | SEC5 HANDLE zero handles launch | **Exigido:** cero handles, sin stdio/HANDLE_LIST, pero STARTUPINFOEX y SECURITY_CAPABILITIES presentes; padre comprueba AppContainer/Job y salida del hijo. | **PASS** |
| 30 | SEC5 APPCONTAINER process query limited denied | **Exigido (C1.2):** QUERY_LIMITED del objetivo ordinario propio denegado 5, objetivo vivo; control positivo ordinario y sin handles filtrados. | **PASS** |
| 31 | SEC5 APPCONTAINER exterior write denied | **Exigido (C1.2):** escritura exterior al destino concedido denegada 5, con control ordinario positivo sobre el mismo fixture y barrera de intento; padre comprueba ausencia de marcador/cambio, nonce privado y descriptor de raíz intactos. | **PASS** |

No reutilizar indiscriminadamente las mutaciones de token v2: `no-il`, `no-sid` y `no-write-restricted` conservan su sentido en la suite **del respaldo**. V3 añade omitir SECURITY_CAPABILITIES → TOKEN/lectura/TERMINATE rojos, reutilizar perfil entre leases → cross-lease rojo, omitir capacidad → runtime positivo rojo, ampliar RX a escritura → runtime immutable rojo. Se mantienen handles, resume-before-job, breakaway y cierre del Job cuando su control discrimine. Restaurar y repetir verde después de cada mutación; no llamar rojo a compilación fallida o entorno contaminado.

### 13.7 Pruebas nuevas obligatorias

Inventario de pruebas nuevas: QUERY_LIMITED ya está implementada y medida en ronda 1 (fila 30 de §13.6); la escritura exterior también está implementada y medida (fila 31, C1.2). **Histórico:** QUERY_LIMITED figuraba como propuesta; escritura exterior no figuraba en este inventario. Las demás filas siguientes conservan el estado de **propuesta**, sin medición v3 acreditada en ronda 1:

| Nombre / estado | Expectativa y medición del coordinador |
|---|---|
| SEC5 APPCONTAINER runtime capability allowed | **PASS exigido**, por Node y Python: misma copia privada inventariada, una sola concesión RX común, perfil A nuevo; arranca y produce nonce/bytes exactos, exit 0, stdout anónimo y cierre completos. |
| SEC5 APPCONTAINER runtime without capability denied | **PASS exigido:** misma copia y ACL RX persistente, perfil B distinto sin capacidad; no lee/ejecuta runtime. Error 5 de apertura/creación o fallo de loader identificado como acceso denegado; 0xC0000142 sin diagnóstico no basta. Control ordinario y con capacidad positivos. |
| SEC5 APPCONTAINER runtime immutable | **PASS exigido:** con capacidad intenta sobrescribir EXE/DLL y crear fichero en runtime; denegado, identidad/hash/SD intactos. No probarlo en instalación real antes de aprobación. |
| SEC5 APPCONTAINER other order separate | **PASS exigido:** A y B concurrentes con SID distinto y la misma capacidad RX; cada uno usa su destino/evento, B no lee/escribe destino/temporales/perfil de A ni afecta sus procesos. Probar también nombres de namespace completos, no solo la invisibilidad relativa. |
| SEC5 APPCONTAINER orphan profile recovered | **PASS exigido:** crash tras intención/create-before-ACK, concesión, Resume y árbol vacío; recuperador propio reiniciado dos veces acredita árbol muerto, ACL originales y perfil eliminado, sin tocar otro perfil propio activo ni perfil fixture ajeno al journal. |
| SEC5 APPCONTAINER profile delete retry | **PASS exigido:** obstáculo de handle propio en almacenamiento, HRESULT/estado registrados; al cerrarlo, limpieza completa/idempotente. Si el SO permite borrar aun con handle, registrar ese comportamiento y sembrar fallo de API para ejercitar retry, sin inventar un fallo real. |
| SEC5 APPCONTAINER private registry allowed | **PASS exigido:** nonce en almacén devuelto por GetAppContainerRegistryLocation, comprobado por padre; HKCU exterior fixture intacto y B sin acceso al almacén de A. |
| SEC5 APPCONTAINER network without capabilities denied | **PASS exigido:** conexión exterior/LAN/loopback denegadas, servidor propio sin solicitud; controles ordinarios conectan. Entorno sin endpoint alcanzable: NO VERIFICADO, no PASS por DNS/timeout. |
| SEC5 APPCONTAINER system read allowed | **PASS exigido:** lectura de nonce/hash en fichero de System32 fijado y lectura RX del runtime; fixture privado solo del usuario permanece denegado. |
| SEC5 APPCONTAINER runtime grant reversible | **PASS exigido:** por copia runtime, SD/DACL/control iniciales inventariados; concesión RX, positiva, reversión por mismo objeto, igualdad final y negativa sin concesión. Árbol protegido y dependencia fuera del runtime con diagnóstico bloqueante. |
| SEC5 APPCONTAINER process query limited denied — **implementada y medida en ronda 1** | **PASS exigido y medido (C1.2):** QUERY_LIMITED del objetivo ordinario propio denegado 5, objetivo vivo; control positivo ordinario y sin handles filtrados. Acreditada por `orq-p1v3-r1d-baseline-20261013.txt` (17/17); expectativa y nombre exacto en §13.6, fila 30. |

La prueba de portapapeles real se reserva al gate de UI de decisión 2, con sesión de prueba propia. P1 no inspecciona contenido del portapapeles habitual.

### 13.8 Sonda de capacidad revisada y mediciones antes de construir

Archivo autorizado: orq-appcontainer_capability_probe-20261010.c. **Corregido estáticamente; no compilado ni ejecutado aquí.** Cambios: perfiles aleatorios sin borrado previo; control ordinario; captura/restauración de DACL por objeto retenido, incluidos descendientes protegidos; rechazo de reparse/hardlinks; RX sin escritura; checks de atributos/Job antes de Resume; stdin válido; argv escapado sin truncamiento; entorno mínimo sin heredar variables de credenciales; stdout con PeekNamedPipe/deadline/límite y EOF; testigo propio vivo cuyo único Job se cierra realmente; liberación de todos los SID/arrays derivados. El testigo prueba muerte del hijo por cierre; la prueba completa de árbol hijo+nieto sigue siendo la del fixture.

La sonda **restaura** la concesión al terminar: «única» describe una ACE común durante su medición, no una autorización para dejar ACL reales cambiadas. Usa copias privadas completas de runtime y dos árboles disjuntos; no ejecutarla sobre C:\Python314 ni alias NVM. Sus snapshots son en memoria: un crash deja esas copias para recuperación/retirada por el coordinador, no acredita el journal durable de producción.

El coordinador asigna variables a rutas privadas existentes y al EXE que él compile. Comandos de ejecución:

```powershell
& $ProbeExe $RuntimeNodeCopy 'node.exe' $WorkNodeCopy '-e' "console.log('SEC5_CAPABILITY_OK')"
& $ProbeExe $RuntimePythonCopy 'python.exe' $WorkPythonCopy '-I' '-B' '-c' "import json, sqlite3; print('SEC5_CAPABILITY_OK')"
```

Antes de **la primera ronda de construcción** debe guardar salida cruda, errores y hashes de la fuente/EXE de estas mediciones:

1. **Capacidad por runtime:** derivación y SID numérico de devAgentsRuntime, control ordinario exit 0, WITH_CAPABILITY exit 0/bytes exactos, WITHOUT_CAPABILITY denegado con causa identificada, monikers distintos y ACL/control finales restaurados. Dependencias Python/DLL y Node completas; runtime sin escritura. No asumir que RX de raíz basta para hijos protegidos.
2. **Lanzamiento y vida útil:** stdout anónimo, stdin EOF, lista de handles, token efectivo AppContainer/capacidad/SID, Job miembro antes de Resume y muerte del testigo al cerrar su único handle. La sonda no acredita por sí sola stderr separado, handle extra excluido ni muerte de nieto: medirlos con el fixture v3 en ronda 1.
3. **Segunda orden real:** dos contenedores simultáneos con la misma capacidad RX; eventos relativos y por ruta completa, destino/temporales/perfil y procesos del otro denegados. La invisibilidad del evento para el padre ordinario ya medida no sustituye esta prueba.
4. **Almacenamiento y frontera:** destino concedido positivo sin relabel, exterior privado lectura/escritura denegados, HKCU exterior intacto y registry privado positivo; red sin capacidades frente a controles alcanzables; WinSta0 READATTRIBUTES/ACCESSCLIPBOARD como observaciones sin consumir clipboard.
5. **Perfiles y ruta de runtime:** create/delete con usuario estándar; un perfil huérfano propio tras crash y reintento de borrado con handles cerrados. Registrar ruta física/identidad/ACL del runtime de NVM y viabilidad de backup/grant/restore en copia. Presentar aprobación concreta al propietario antes de ACL reales.

Los puntos 3–5 pueden requerir sondas nuevas del **coordinador**, no una modificación de core/tests/tools en este encargo. Un fallo bloquea el mecanismo o transporte afectado; no se convierte en respaldo automático.

### 13.9 Plan de construcción: tres rondas pequeñas

**Plan histórico previo a ronda 1:** se redactó para una autorización futura de implementación; aquel encargo terminaba en documentación y revisión de la sonda, sin ejecutar estas rondas. El estado medido de ronda 1 se registra al final de esta sección; las rondas 2 y 3 siguen como plan pendiente.

| Ronda | Trabajo acotado | Criterios numerados de salida | Medición del coordinador |
|---|---|---|---|
| **1 — AppContainer mínimo y fronteras** | Adaptar el lanzador/fixture existentes al perfil efímero, SECURITY_CAPABILITIES, destino propio y stdio/Job; mantener backend restringido separado. Sin rutas S de producción ni ACL de instalaciones reales. | **C1.1** token/SID/cero handles correctos; **C1.2** destino positivo y exteriores/proceso TERMINATE/VM_WRITE/QUERY_LIMITED denegados; **C1.3** otra lease en otro contenedor no señala el evento de A; **C1.4** stdio, exclusión de handles, fallo antes de Resume y Job hijo+nieto/cierre/crash completos; **C1.5** mapeo discriminante de las siete mutaciones restringidas revisado contra el fixture vigente: `no-sid` → `SEC5 TOKEN effective child` (falta el SID de lease), sin reutilizar el objetivo obsoleto de escritura ajena; **C1.6** las siete variantes `no-il`, `no-sid`, `no-write-restricted`, `breakaway-ok`, `no-handle-list`, `resume-first`, `restore-auto-inherit` con rojo específico demostrado y baseline completa restaurada en verde, sin obligatorios omitidos; cualquier `RED_NOT_DEMONSTRATED` bloquea el cierre aunque se midan las demás. | coordinador con usuario estándar **fuera del sandbox**: evidencia cruda por cada una de las siete mutaciones restringidas y su verde restaurado, nombres/efectos discriminantes, código de salida y hashes; no se presentan esos verdes restringidos como PASS de AppContainer v3. Además: controles ordinarios, efectos/SD/nonce por padre, token suspendido y nieto, membership exacto; baseline acotada con nombres contabilizados; mutaciones de ausencia AppContainer, reutilización de perfil, handles, orden de Resume y Job, restauración verde. |
| **2 — Runtime y matriz completa** | Capacidad RX común, entorno/temporales privados, Node/Python fijados y receta registry/IPC necesaria. Concesión solo en copias mientras no exista aprobación concreta de ACL reales. | **C2.1** con/sin capacidad discriminante en ambos runtimes; **C2.2** runtime immutable y RX reversible; **C2.3** los 31 nombres (29 heredados y dos adicionales de C1.2) y nuevas pruebas de runtime/registry/red/lectura medidos, observaciones completas y ningún obligatorio FAIL/SKIPPED; **C2.4** otra orden comparte RX pero no datos/objetos/procesos. | Matriz v3 completa separada de baseline restringida; imports/DLL reales, hashes/ACL antes-después, HKCU/servidores fixture, destinos y cachés. Mutaciones omitir capacidad y dar escritura al runtime deben producir rojos específicos, después verdes. WinSta0 queda observación de UI. |
| **3 — Ciclo de perfil y recuperación** | Añadir registro durable mínimo y recuperación de perfiles/ACE de fixtures según §13.2, reutilizando el contrato de journal de §7; sin migrar bases reales ni ampliar P1 a rollout P2–P7. | **C3.1** crashes en cada frontera no dejan árbol ni concesión utilizables tras recovery; **C3.2** huérfano create-before-ACK y borrado/retry idempotentes; **C3.3** identidad divergente/journal corrupto bloquean, otra orden activa/fixture ajeno no se toca; **C3.4** matriz completa, mutaciones discriminantes, regresión global y revisión independiente con evidencia. | Broker/recuperador separados, dos arranques de recovery por escenario, árbol vacío verificado, SD/control/identidades y perfil final; mutar ausencia de intención durable o limpieza antes de árbol vacío para rojo específico. Registrar latencia create/delete y residuos, sin presupuesto inventado. |

Cada ronda guarda evidencia por tarea en `la documentación interna`; ejecutar suite de regresión al terminar cada ronda de construcción y la global al cierre de P1. No reutilizar resultados v2 como PASS v3 ni firmar AUDIT PASS propio. Para futuras compilaciones rige mínimo **15 GiB** y caché nueva por sesión del entorno vigente; el mínimo histórico de §12 no autoriza compilar en este encargo.

**13-oct-2026 — Estado medido de ronda 1:** AppContainer 17/17 PASS (`orq-p1v3-r1d-baseline-20261013.txt`); restringido 23 PASS / 0 FAIL / 6 observaciones (`orq-p1v3-r1d-restricted-baseline-20261013.txt`); 16/16 mutaciones con rojo demostrado y verde restaurado (nueve AppContainer y siete restringidas, `orq-p1v3-r1d-mutations-appcontainer-20261013.txt` y `orq-p1v3-r1d-mutations-restricted-20261013.txt`); auditoría del segundo auditor **PASS CON CAMBIOS** (informe archivado en el registro de evidencias privado). Regresión: el fallo histórico de `cabina_ux.test.cjs` se debía a la ausencia del Chrome headless de Puppeteer en `~/.cache/puppeteer`; la prueba pasa con el Edge del sistema mediante `DEVAGENTS_TEST_BROWSER` (`orq-p1v3-r1d-cabina-ux-edge-20261013.txt`, EXIT_CODE=0). Evidencias en el registro privado de evidencias; la regresión global sigue en curso y no se declara cerrada aquí.

### 13.10 Riesgos y preguntas para el propietario (máximo tres)

Son decisiones pendientes sobre alcance futuro, no solicitudes para terminar esta entrega documental.

| Riesgo / pregunta | Opción recomendada | Alternativa y coste |
|---|---|---|
| **1. ¿Autorizar una concesión RX única a devAgentsRuntime sobre las instalaciones físicas medidas de Node/Python, con backup y reversión?** Los paquetes con esa capacidad tendrán RX común; una actualización puede invalidar ACL/identidades. | **Sí, después de la sonda positiva/negativa**, mostrando versión, SID e inventario; sin padres globales ni alias mutable. Ante cambio de versión, revalidar. | No modificar instalaciones: mantenerlas incompatibles hasta otra ubicación externa administrada por el propietario o capacidad por runtime aprobada; no empaquetar runtimes. |
| **2. ¿Qué uso operativo tendrá el respaldo restringido que permite TERMINATE y objetos entre leases?** | **Solo medición/diagnóstico explícito por ahora.** Ninguna caída automática desde AppContainer; producción S bloqueada ante incompatibilidad. | Permitir ejecuciones concretas explícitas con riesgo/registro y sin promesa v3/H3; requiere decisión adicional del propietario. |
| **3. ¿Mantener una capacidad común de runtimes o separar por runtime?** RX común amplía la lectura/ejecución al conjunto concedido y no autentica a DevAgents. | **Una capacidad común en P1**, limitada a RX e inventario de los dos runtimes, para medir la hipótesis solicitada; sin capacidades en datos/IPC. | Capacidades separadas por runtime reducen ese conjunto pero añaden aprovisionamiento/controles; evaluarlas después si la medición muestra necesidad. |

No se reabre la elección AppContainer ni la excepción E ya decididas. LPAC y aislamiento de UI tienen gates posteriores; su ausencia no se disfraza como aislamiento integral.

**2026-10-13 — Decisiones del propietario (fuente: `la documentación interna` §12 de main,):** (1) concesión RX única sobre los runtimes reales de Node/Python solo con respaldo y reversión de ACL probados antes; si no, no; (2) respaldo por token solo diagnóstico, sin caída automática; (3) una capacidad común limitada a los dos runtimes. Esta ronda 1 no modifica instalaciones reales.

### 13.11 R1C — restauración cross-lease y recuperación puntual

La baseline R1B del coordinador midió el aislamiento cross-lease, pero falló al restaurar la copia privada de `sec5-child.exe`: el handle tenía `READ_CONTROL | WRITE_DAC` y `restore` solicitaba también OWNER, GROUP y LABEL, que necesitan `WRITE_OWNER`. R1C retiene los tres derechos desde la captura y registra objeto, ruta, handle y máscara en caso de fallo. Los eventos del hijo solo se leen/comparan; no se cambia su descriptor.

Cross-lease usa ahora un fixture completo separado, con su copia privada y dos perfiles. Un fallo de aislamiento/restauración sigue siendo FAIL; las pruebas de handles, fallo antes de Resume y Jobs continúan en el fixture principal. Una limpieza aislada fallida también mantiene `cleanup=0` en el resumen global.

Recuperación de los restos concretos de R1/R1B, con usuario estándar y sin otra ejecución SEC5 activa:

```powershell
Set-Location -LiteralPath 'C:\devagents\sec-os'
& .\zig-out\bin\sec5-os.exe recover
```

El modo no acepta rutas/monikers arbitrarios: solo las carpetas `.sec5-fixture-f291ee5c-0738-45ef-b487-0ce8336a99cb` y `.sec5-fixture-597f593a-15b1-41f3-b7cf-9c5fae3a4b44`, y los monikers `DevAgents.Sec5.31d073d04b076121d09153ba19ab9ecf`, `DevAgents.Sec5.a2c26bf9744fa118b6b2a2e0acd6c1f4` y `DevAgents.Sec5.dc21081a01f59fd5c1f92abc8c92df83`, registrados en las dos baselines del 13-oct. Deriva/contrasta SIDs, exige el usuario registrado y ausencia de procesos SEC5 concurrentes; comprueba propietario/grupo y trustees de los objetos a restaurar, captura identidades actuales, restaura los descriptores de creación y compara su semántica. Elimina por handles relativos al árbol fijado, rechazando reparse/hardlinks, y solo después invoca `DeleteAppContainerProfile` sobre esos nombres exactos. Admite ausencia/reintento; no termina procesos ni barre `Packages`, HKCU o datos de DevAgents.

Es recuperación manual limitada a estos incidentes, no el journal durable de ronda 3: las baselines antiguas no guardaron FileId pre-crash. Las identidades se fijan al iniciar `recover`; una discrepancia impide continuar. Recuperación, baseline R1C, mutaciones y regresión quedan NO VERIFICADAS en SO hasta que las ejecute el coordinador. Evidencia e informe R1C: `la documentación interna*-20261013.txt` e `INFORME-SOL-LOTE5-P1V3-R1C-20261013.md`.

### 13.12 R1D — entorno efectivo del broker y originales de recuperación

El broker ordinario recibe el bloque explícito construido en `launch_run`, no el entorno completo del padre. R1C omitía `LOCALAPPDATA` por `!ordinary`, aunque el broker necesitaba esa variable para crear su hijo AppContainer. R1D la incluye también en los procesos ordinarios de la suite AppContainer. Un fallo se informa mediante paquete binario por stdout y `BROKER_LAUNCH_FAILED` por stderr; el broker no espera liberación ni simula el crash del modo 1 cuando el lanzamiento falla, y sale con 105.

`recover` usaba plantillas con derechos genéricos GA como originales. Los snapshots guardados en las baselines R1/R1B contienen derechos de archivo FA, ya mapeados al crear los objetos; la comparación de ACE no acepta GA como idéntico a FA. R1D restaura los SDDL guardados (incluidas las etiquetas ME/LW) y verifica OWNER/GROUP/DACL/etiqueta efectiva. Retira únicamente las ACE de los paquetes registrados y comprueba la DACL restante por handle. El original guardado del ejecutable ya incluía A: se restaura y verifica antes de revocar esa concesión de creación para eliminar la copia privada. Continúan las listas exactas de R1/R1B, el borrado relativo por handles y la eliminación de perfiles después del árbol. La ausencia del árbol y `DeleteAppContainerProfile` sobre un perfil inexistente permiten el reintento sin nuevas concesiones.

Compilación/formato y hashes R1D: `la documentación interna*-20261013.txt`. La matriz no se ejecuta en esta ronda por orden del propietario. El resultado real de recuperación e idempotencia debe distinguirse de la corrección compilada en el informe R1D.

### 13.13 R2 — capacidad común y matriz de runtime (constructor, 13-oct)

Modo explícito `-RuntimeMatrix`, separado de la baseline R1: conserva los 31 nombres y añade las ocho filas de runtime, otra orden, registry, red y lectura de sistema de §13.7 que corresponden a ronda 2. Inventario exigido: 39 filas medidas (35 obligatorias y cuatro observaciones completas: MIC, pipe ordinario, WinSta0 e herencia). Los perfiles huérfanos/borrado retry siguen en ronda 3. Ninguna medición de SO de esta implementación se ejecuta dentro de Codex; compilación y formato no acreditan C2.1–C2.4 ni la continuidad 17/17 de R1.

`tools/sec5_runtime_copies.ps1` prepara únicamente `.sec5-r2-runtimes-20261013/node` y `/python` bajo este worktree, con Node físico resuelto y Python 3.14 completo, inventario de identidad/SD/SHA256 y descendiente protegido. Nunca cambia ACL del origen. El fixture deriva un único `devAgentsRuntime`, captura y retiene todos los objetos, concede RX por objeto sin herencia ni cambios de label/owner, compara hashes/SD/control y revierte DACL por los mismos handles. Datos y procesos reciben permisos del paquete de su orden; la capacidad común no aparece en sus concesiones. El script de retirada solo admite la raíz privada fija. Los snapshots no sustituyen al journal durable de ronda 3; después de un crash, conservar evidencia y retirar explícitamente las copias privadas antes de recrearlas.

Node/Python ejecutan inline, leen un testigo dentro de la copia y generan nonce exacto en stdout, destino y caché privada; Python importa JSON/SQLite y rechaza módulos/prefijos fuera de la copia. La negativa usa otro perfil, con la misma RX persistente, y un testigo nativo identifica error 5 sobre EXE/DLL/stdlib/script antes de registrar el intento real de ejecución. El aviso `Failed to find real location of <ruta privada exacta>` de CPython 3.14, ya medido en `orq-pre-r1e-python-run-20261011.txt`, se admite exclusivamente como observación en stderr separado; otras salidas de error bloquean. Python stdout exige CRLF exacto; Node exige LF exacto.

Registry usa `GetAppContainerRegistryLocation`, nonce privado y comprobación del padre mediante el token de su hijo propio; B intenta el nombre NT completo de esa clave. IPC autorizado usa el handle exacto del evento; el pipe ordinario conserva su observación sin habilitar ese transporte. Red requiere `SEC5_NET_EXTERNAL`, `SEC5_NET_LAN`, `SEC5_NET_LOOPBACK`: IPv4 pública, RFC1918 y loopback respectivamente, con el protocolo de `tools/sec5_network_server.ps1`. Eco ordinario positivo y contador sin petición nueva son obligatorios. Solo `WSAEACCES` (10013) o `WSAETIMEDOUT` (10060) del contenedor cuentan como denegación bajo esos controles; cualquier otro error falla. La ausencia de EXTERNAL se nombra aparte y bloquea la fila conjunta aunque LAN/loopback estén medidos.

Mutaciones de R2: `no-runtime-capability` debe poner rojo `SEC5 APPCONTAINER runtime capability allowed`; `runtime-write` debe poner rojo `SEC5 APPCONTAINER runtime immutable`. `tools/sec5_evidence.ps1 -RuntimeMatrix -Mode mutations` exige ambas parejas rojo/verde, con restauración completa. Comandos, hashes y pendientes del constructor: `la documentación interna`. No se firma cierre ni AUDIT.

### 13.14 R2C — temp efectiva, autoherencia y observaciones (13-oct)

Windows deriva TEMP/TMP a `<LOCALAPPDATA de entrada>/Packages/<moniker>/AC/Temp`. El fixture prepara esa ruta bajo el destino privado antes de lanzar A o B con entorno privado; la DACL heredada debe contener exactamente una ACE de paquete, el SID de su orden, sin capacidad común. El control ordinario, npm y Python usan la misma Temp final, y el padre exige los bytes de caché en esa ubicación. No se usa la temp del usuario como caché de runtime.

La concesión y reversión de DACL por handle conservan `SE_DACL_AUTO_INHERITED` solicitando además `SE_DACL_AUTO_INHERIT_REQ` cuando el original tenía AI; el kernel consume la solicitud. El snapshot original permanece intacto. Continúan las comparaciones de identidad, ACE (incluida herencia), controles, SD y hash. La mutación restringida `restore-auto-inherit` conserva su setter defectuoso independiente.

MIC registra CREATE_ALWAYS sobre recurso medio, con y sin ACE de paquete, bajo controles ordinarios de nonce positivo. Win32 5 y 1314 sin archivo creado son resultados de denegación observados; 1314 se identifica como privilegio para creación con etiqueta heredada, no como prueba general de aislamiento MIC. LABEL sin WRITE_OWNER es un control negativo esperado: solo Win32 5 con SD intacto da PASS y su diagnóstico lo declara expresamente. Informe y evidencias: `la documentación interna` y `sol-p1v3-r2c-*-20261013.txt`. Compilación/formato no sustituyen las mediciones externas de R1/R2.
