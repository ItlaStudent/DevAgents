# ADR-B009 — Aislamiento principal de órdenes mediante AppContainer

**Estado**: Aceptada para el mecanismo principal; diseño P1 v3 pendiente de medición y auditoría · **Fecha**: 2026-10-10 · **Decide**: usuario (propietario del proyecto)
**Referencia**: Constitución v4.0.0; decisión 4 del propietario; [SEC5 §13](../SEC5-AISLAMIENTO.md#13-diseño-v3-appcontainer).

## Contexto

P1 necesita limitar las órdenes S a recursos concedidos y contener sus descendientes sin afectar procesos ordinarios del usuario ni compartir objetos de sesión entre órdenes. La decisión 4 cambia el mecanismo principal; la excepción E de la decisión 1 y la separación de UI de la decisión 2 siguen vigentes.

Las siguientes son mediciones del coordinador, con usuario estándar fuera del sandbox de Codex, aceptadas como hechos. Este ADR no presenta una implementación AppContainer de P1 como verificada.

| Evidencia bajo `la documentación interna` | Hecho medido |
|---|---|
| sec5-baseline-20261010-054945-609-02.txt | Token restringido: **23 PASS, 0 FAIL, 6 observaciones, 29 nombres**. `PROCESS_TERMINATE` sobre un proceso ordinario del usuario y señalización de evento del hijo desde otra lease: `OBSERVED_ALLOWED`. Mutex y acceso a WinSta0, incluido `WINSTA_ACCESSCLIPBOARD`, permitidos. Las observaciones no son pruebas de aislamiento. |
| orq-bno_default_dacl-20261010.py y la línea base anterior | El evento con nombre y SD NULL hereda la DACL del directorio de sesión, no la `TokenDefaultDacl`. Cambiar esta última no cierra el acceso entre leases. |
| orq-appcontainer_probe-20261010.c, salida orq-appcontainer-medicion-20261010.txt | `TERMINATE` y `QUERY_LIMITED` contra proceso ordinario: error **5**; evento del usuario: **5**. Evento propio invisible al usuario mediante el mismo nombre: **2**, por espacio de nombres propio. Escritura concedida: OK; escritura en perfil del usuario: **5**; lectura de System32: OK. |
| ACL de runtimes, en esa misma salida | `C:\Python314` y `C:\nvm4w\nodejs` no conceden RX a ALL APPLICATION PACKAGES; Program Files sí. No se extrapola la concesión del directorio a todos sus descendientes ni a DLL/imports exteriores. |
| orq-appcontainer_capability_probe-20261010.c | **Sin ejecutar**: comprobar RX mediante la capacidad propia `devAgentsRuntime`, con control sin capacidad, stdout anónimo, perfiles distintos y cierre efectivo del Job. Revisión corregida en este encargo; compilación y ejecución corresponden al coordinador. |

## Alternativas consideradas

| Opción | Ventaja | Coste / limitación | Resolución |
|---|---|---|---|
| Token restringido P1 ronda 5 | Compatibilidad Node/Python y límites de escritura ya medidos; conserva el trabajo previo. | Residuos confirmados de TERMINATE, objetos entre leases, mutex y WinSta0. No cumple la nueva exigencia de aislamiento entre órdenes. | Respaldo explícito y medido; no camino principal ni degradación automática. |
| **AppContainer convencional** | Medición local cierra TERMINATE y acceso a objetos del usuario; proporciona SID/namespace separado. API nativa del SO. | Preparación de runtimes sin RX, perfiles efímeros y limpieza; accesos ambientales de ALL APPLICATION PACKAGES. | **Elegida**, conforme a la decisión 4. |
| LPAC | Reduce los accesos ambientales concedidos al AppContainer convencional. | No medido; exige capacidades adicionales para recursos como registro/COM y nueva matriz de compatibilidad. | Evaluación posterior con gate propio; no añade permisos para fingir compatibilidad en P1. |
| AppContainer + token restringido | Posible defensa adicional conservando ambos mecanismos. | Intersección de controles y SIDs; puede repetir incompatibilidades de arranque. No hay medición de eficacia o necesidad adicional. | No se combina en P1 v3. Solo reconsiderar ante un residuo concreto y medido. |

El modelo documentado de AppContainer combina permisos del usuario y del paquete/capacidades. LPAC opta fuera de ALL APPLICATION PACKAGES y requiere concesiones adicionales. Estos contratos justifican las opciones; la viabilidad local depende de las sondas. [Documentación de lanzamiento de Microsoft](https://learn.microsoft.com/en-us/windows/win32/secauthz/implementing-an-appcontainer).

## Decisión

1. El camino S principal será **AppContainer convencional, sin red**, con perfil y SID nuevos por lease de una orden. El perfil no se comparte entre órdenes; los descendientes de esa lease comparten su frontera. Un reintento tras cierre/recuperación crea otra lease y perfil.
2. El broker conserva autoridad, entrada por identidad/hash, destino preparado, Job sin breakaway y lista exacta de handles. AppContainer no sustituye esos contratos ni migra por sí solo los sitios S existentes.
3. Runtimes: proponer al propietario una concesión **única RX a `devAgentsRuntime`** por instalación física inventariada, con respaldo/reversión de DACL. La sonda debe demostrar primero con-capacidad positivo y sin-capacidad negativo. La decisión 4 no autoriza ejecutar ya el cambio de ACL sobre las instalaciones reales.
4. Temporales y destino reciben el SID del paquete de esa lease; nunca la capacidad compartida de runtime. No se conceden ALL APPLICATION PACKAGES, WRITE_DAC o WRITE_OWNER para resolver arranques.
5. El token restringido conserva su línea base y sus residuos como respaldo. Su uso requiere selección explícita y riesgo registrado; un fallo de AppContainer bloquea el lanzamiento S normal. No produce PASS de P1 v3 ni habilita automáticamente producción.
6. Los CLIs E siguen fuera de la garantía, registrados y etiquetados **«CLI externo sin aislamiento de DevAgents»**. P1 permanece sin GUI; el portapapeles/WinSta0 se caracterizan sin atribuir aislamiento de UI.

## Consecuencias

**Positivas**

- TERMINATE y acceso a objetos entre contenedores pasan de observaciones a denegaciones obligatorias, verificadas por el padre sobre fixtures propios.
- Runtimes se conceden una vez mediante capacidad estable; datos y namespaces mantienen identidad por lease.
- Se reutilizan contratos, Job, handles, ACL/journal y pruebas existentes, sin nuevos lenguajes, runtimes empaquetados ni dependencias externas.

**Costes y riesgos aceptados en el diseño, pendientes de gates**

- Un perfil huérfano exige recuperación durable; borrar el perfil no revoca handles vivos ni restaura ACE sobre destinos externos.
- La capacidad común permite RX en todos los runtimes concedidos a quienes la posean. No es un secreto ni autentica a DevAgents; nunca autoriza escritura o acceso a datos de otra orden.
- Las actualizaciones de runtimes pueden cambiar identidad, ACL o dependencias. Se revalida la instalación; no se persigue un alias mutable ni se amplía RX a padres globales.
- Se pierde la lectura ambiental general del token WRITE_RESTRICTED: solo se promete lectura concedida y lectura ambiental medida. System32 sí se observó; confidencialidad integral, UI y servicios intermediarios no se declaran resueltos.
- La aceptación del mecanismo por el propietario no es AUDIT PASS. La matriz, las tres rondas y los gates están en SEC5 §13; esta entrega documental no compila ni altera el lanzador actual.
