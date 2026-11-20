# Verificación de avisos salientes

Cada intento lleva `X-DevAgents-Timestamp` (segundos Unix UTC, decimal) y
`X-DevAgents-Delivery` (128 bits aleatorios, 32 caracteres hexadecimales en
minúscula). El identificador cambia en cada intento, también en un reintento.
Sin secreto configurado, estas cabeceras no autentican el aviso.
Un fallo al consultar el reloj SQL o una marca no positiva impide reclamar
el envío; se devuelve el error y no se sustituye por un timestamp ficticio.

Con secreto, `X-DevAgents-Signature` tiene el formato `sha256=<64 hex>` y se
calcula con HMAC-SHA256 sobre estos bytes, sin salto final añadido:

```text
timestamp + "." + delivery + "." + cuerpo HTTP exacto
```

El cuerpo es el JSON existente (`version`, `order_id`, `event`) o el texto de
ntfy. La firma anterior del cuerpo solo deja de ser válida: los receptores deben
actualizar su verificación. Nunca analizar y volver a serializar el cuerpo antes
de comprobarlo; hay que conservar los bytes recibidos.

El receptor debe rechazar cabeceras ausentes o duplicadas, formato incorrecto,
marca de tiempo a más de 300 segundos de su reloj UTC o HMAC distinto. Comparar
el HMAC en tiempo constante. Mantener un almacén de ids aceptados al menos hasta
que su timestamp quede fuera de esa ventana; comprobar e insertar el id en una
única operación atómica antes de ejecutar el aviso. Un replay dentro de la
ventana se rechaza, y fuera de ella lo rechaza el timestamp. Sincronizar los
relojes de emisor y receptor.

Un reintento tiene otro id; para acciones con efecto persistente el receptor
debe aplicar además su deduplicación por orden/evento. El envío conserva el
máximo de tres intentos, su plazo total de 5 segundos, la política de destino
y el rechazo de redirecciones.

La firma y el secreto no aparecen en la línea de comandos de curl. El motor
usa `--config -`: la configuración con cabeceras y `data-binary` pasa por stdin
al ejecutor fijado. Las comillas, barras y controles permitidos se escapan
según el [formato oficial de configuración de curl](https://curl.se/docs/manpage.html#--config).
No se crea un archivo con esas cabeceras. Se ponen a cero el secreto descifrado,
el estado HMAC, la firma y la configuración temporal al terminar.

## Retención

`DEVAGENTS_NOTIFICATION_RETENTION_ROWS` configura la retención del proceso:
entero entre 128 y 100000, por defecto 4096. Se fija en el entorno antes de
arrancar el motor/cabina; no necesita cambios de esquema ni acceso a catalog.db.
Un valor numérico fuera de rango o no numérico devuelve `InvalidRetention`:
el dispatcher registra el error y el sondeo de avisos lo devuelve al llamador.
Una variable ausente o vacía usa el valor predeterminado.

Cada tick del dispatcher y cada consulta de notificaciones elimina como máximo
128 filas antiguas por tabla. Conserva el intervalo de ids más reciente según
la retención configurada; en `webhook_outbox` solo elimina `sent` y `failed`.
`pending` y `sending` permanecen en cola, aunque sean antiguos; por ello una
cola pendiente puede superar la retención. La purga converge en sucesivos ticks
y mantiene ids recientes de `order_notifications`, evitando reutilizar el
cursor de la tabla heredada. No elimina órdenes ni eventos del historial.

La notificación se encola en la misma transacción que el cambio de estado de
la orden (triggers de la migración V44). Si SQLite no puede insertar en el
outbox, tampoco puede guardar el estado: los dos comparten la base, y lo normal
es que la causa (disco lleno, base bloqueada) impida ambas cosas. Se conserva
esa atomicidad a propósito (decisión del 12-nov-2026 al integrar `e5-harden`):
un aviso nunca anuncia un estado que no quedó guardado.

Desde MCP no se pueden crear receptores con `allow_private=true`: ese permiso
solo se da desde la cabina.
