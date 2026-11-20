# Acceso remoto a las órdenes

El motor sirve una página móvil en español, sin recursos externos. Está apagado
por defecto. La cabina activa un **proceso hijo del motor**, nunca un servidor
HTTP dentro de `devagents-host.exe`; el hijo valida la red y envía las operaciones
por una tubería local privada a las mismas funciones C-ABI de la cabina. Así una
aprobación afecta a la orden viva y no a una copia de su historial.

Para un motor independiente:

```powershell
devagents-core.exe remote serve --data-dir C:\ruta\datos --port 49180
```

Sin `--port`, Windows asigna un puerto libre aleatorio. La primera línea de stdout
muestra la URL y el token **una sola vez**. No redirija esa línea a evidencias,
logs ni capturas. Al reiniciar cambia el token. Se conserva SHA-256, nunca el token
en claro: `remote_token.sha256` junto a la base independiente. La cabina usa un
archivo de hash temporal propio y lo retira al apagar el servicio.

Introduzca el token en la página. Se guarda exclusivamente en `sessionStorage`
de esa pestaña y se borra al pulsar **Salir**. Todas las operaciones usan
`Authorization: Bearer`; no hay cookies. No introduzca el token en la URL.

## Túneles del usuario

La dirección del listener es la constante `127.0.0.1`. `--bind` admite únicamente
ese literal; una IP de LAN, `0.0.0.0`, `localhost` o IPv6 son un error. No cree
reglas de firewall ni redirecciones de router para este puerto.

Desde otro equipo con SSH hacia el equipo del motor:

```sh
ssh -N -L 49180:127.0.0.1:49180 usuario@equipo-del-motor
```

Abra `http://127.0.0.1:49180` en ese equipo. Mantenga el mismo puerto en ambos
lados para que la comprobación de `Origin` coincida. SSH cifra el transporte.
El teléfono necesita su cliente SSH con redirección local y conexión de confianza.
La opción `-L` sigue el [manual oficial de OpenSSH](https://man.openbsd.org/ssh.1#L).

Con Tailscale instalado y autenticado por el usuario:

```sh
tailscale serve --bg http://127.0.0.1:49180
```

Copie el origen HTTPS que muestra Tailscale y arranque el motor con su origen
exacto, sin barra final:

```powershell
devagents-core.exe remote serve --data-dir C:\ruta\datos --port 49180 --origin https://equipo.red.ts.net
```

Abra esa URL dentro de su tailnet. Tailscale aporta TLS; el token sigue siendo
obligatorio. No active Funnel. `tailscale serve reset` retira el túnel. La prueba
con teléfono y túnel reales corresponde al propietario.
La receta sigue la [referencia oficial de Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve).

## Contrato acotado

Solo se admiten estos endpoints JSON, con las operaciones de la misma C-ABI:

| Método y ruta | Operación |
| --- | --- |
| `GET /api/orders` | Listar órdenes |
| `GET /api/orders/<id>` | Detalle de una orden |
| `GET /api/orders/<id>/events?since=<id>` | Eventos posteriores al cursor |
| `GET /api/approvals` | Aprobaciones pendientes |
| `POST /api/approvals/<id>` | `{ "approved": true/false }` |
| `POST /api/orders/<id>/approve` | `{}`; aprobar y despachar el plan |
| `POST /api/orders/<id>/cancel` | `{}`; cancelar la orden |

Cada petición de mutación deja `remote_action` en el historial de la orden,
con la acción y fase `requested`; la transición real sigue en los eventos
habituales de aprobación, despacho o cancelación. Una acción rechazada devuelve
409 y el evento no afirma que se ejecutó.

## Modelo de amenaza y límites

El listener exige un token aleatorio de 256 bits, compara su SHA-256 en tiempo
constante, valida `Host` contra loopback o el origen autorizado (un `Host`
ausente, vacío o duplicado es 400; uno ajeno, 403) y rechaza un `Origin` ajeno
(incluido `null`). El origen adicional de `--origin` debe ser `https://` salvo
en loopback, sin ruta, usuario, consulta ni fragmento. El acceso remoto solo se
inicia desde la cabina o con `devagents-core.exe remote serve`: la herramienta
MCP `remote_start` lo rechaza, porque un cliente MCP es un agente y no debe
recibir el token. Las peticiones sin `Origin`, usadas por clientes
HTTP no navegadores, siguen necesitando el token. Rechaza cookies, transferencia
chunked, cabeceras duplicadas relevantes, métodos y rutas fuera de la lista.
No habilita CORS público. Respuestas `no-store`, `nosniff`, sin referente y con
CSP que impide marcos y recursos externos. Solo se sirve HTML para la página
embebida y JSON para la API.

Las cotas son 8 KiB de cabeceras, 8 KiB de cuerpo, 1 MiB de respuesta y 120
peticiones autenticadas por minuto para el servicio. Cada conexión tiene un
plazo de 5 s. El servidor serializa las conexiones; un cliente local puede
agotarlo temporalmente. El límite es de servicio, no por IP: todos los clientes
del túnel llegan por loopback. Una página maliciosa no obtiene el token; el texto
de órdenes, eventos y aprobaciones se inserta con `textContent`, nunca como HTML.

El túnel y el equipo local son de confianza. Otro proceso del mismo usuario
puede leer memoria, interceptar datos o controlar el motor: esto no es un
sandbox frente a ese usuario ni frente a malware en su cuenta. El token concede
lectura del historial y las acciones indicadas; trátelo como una credencial.
Cerrar la pestaña no apaga el motor. Apague el acceso desde la cabina o termine
solo el proceso que lanzó explícitamente. El motor independiente no se debe
abrir sobre una base que otro proceso motor esté usando para órdenes vivas;
para esas órdenes use la cabina y su broker privado.

Los avisos salientes tienen una política separada: por defecto rechazan
loopback, link-local, redes privadas, ULA IPv6 y metadatos. El motor comprueba
todas las IP resueltas al enviar y fija la conexión a una IP validada mediante
[`--connect-to`](https://curl.se/docs/manpage.html#--connect-to), conservando
el nombre del receptor para Host y TLS. DNS y envío comparten el plazo de 5 s.
No sigue redirecciones; un 3xx se registra como `RedirectRejected`.

Solo `allow_private=true` permite esos destinos para un webhook concreto.
La casilla de ajustes muestra la advertencia de acceso a redes privadas y
metadatos; la herramienta MCP `webhook_add` rechaza `allow_private=true`.
La firma de cada aviso se describe en [WEBHOOK-VERIFICACION.md](WEBHOOK-VERIFICACION.md). Los receptores anteriores
migran con el opt-in desactivado; el listado UI/MCP muestra la opción persistida.
El receptor de pruebas loopback lo activa explícitamente. No active este permiso
para una URL que no controle.
