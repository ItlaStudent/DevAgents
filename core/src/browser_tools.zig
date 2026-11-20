//! Single browser.v1 catalog for the worker and the future MCP adapter.
//! Model arguments never carry engine identity, host generation or leases
//! other than the explicit server generation selector.
const std = @import("std");
const providers = @import("providers");

pub const MAX_ARGUMENT_BYTES = 64 * 1024;
pub const CATALOG = [_]providers.connector_v2.ToolDefinition{
    .{ .name = "browser_navigate", .description = "Abre una dirección (action=url, wait=load) o va atrás, adelante, recarga o detiene la carga en una pestaña del navegador integrado. Un sitio nuevo espera la aprobación del usuario. Un archivo del proyecto se abre con su ruta relativa (index.html).", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"action":{"type":"string","enum":["url","back","forward","reload","stop"]},"url":{"type":"string","minLength":1,"maxLength":8192},"wait":{"type":"string","enum":["domcontentloaded","load"]}},"required":["session_id","tab_id","action","wait"],"additionalProperties":false,"oneOf":[{"properties":{"action":{"type":"string","enum":["url"]}},"required":["url"]},{"properties":{"action":{"type":"string","enum":["back","forward","reload","stop"]}},"not":{"required":["url"]}}]}
    },
    .{ .name = "browser_snapshot", .description = "Lista los elementos visibles e interactivos de la página (enlaces, botones, campos, encabezados) con su referencia ref (e0, e1…), el snapshot_id y la view_revision. Úsalo antes de hacer clic o escribir.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":5000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"frame":{"type":"string","minLength":1,"maxLength":256},"root_ref":{"type":"string","minLength":1,"maxLength":256},"cursor":{"type":"string","minLength":1,"maxLength":256}},"required":["session_id","tab_id"],"additionalProperties":false}
    },
    .{ .name = "browser_find", .description = "Busca elementos por role, name o text y devuelve sus referencias (ref) con un snapshot_id nuevo.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":5000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"query":{"type":"object","properties":{"role":{"type":"string","minLength":1,"maxLength":256},"name":{"type":"string","minLength":1,"maxLength":256},"text":{"type":"string","minLength":1,"maxLength":256},"exact":{"type":"boolean"}},"required":[],"additionalProperties":false,"minProperties":1},"frame":{"type":"string","minLength":1,"maxLength":256},"cursor":{"type":"string","minLength":1,"maxLength":256}},"required":["session_id","tab_id","query"],"additionalProperties":false}
    },
    .{ .name = "browser_text", .description = "Lee el texto visible de la página (scope=page) o de un elemento (scope=ref con target {ref, snapshot_id}).", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":5000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"scope":{"type":"string","enum":["page","ref"]},"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"cursor":{"type":"string","minLength":1,"maxLength":256}},"required":["session_id","tab_id","scope"],"additionalProperties":false,"oneOf":[{"properties":{"scope":{"type":"string","enum":["page"]}},"not":{"required":["target"]}},{"properties":{"scope":{"type":"string","enum":["ref"]}},"required":["target"]}]}
    },
    .{ .name = "browser_click", .description = "Hace clic en un elemento: target {ref, snapshot_id} de browser_snapshot o browser_find (o {x, y, view_revision}). Devuelve la URL, el título y la revisión resultantes.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"button":{"type":"string","enum":["left","right","middle"]},"count":{"type":"integer","minimum":1,"maximum":2}},"required":["session_id","tab_id","target","button","count"],"additionalProperties":false}
    },
    .{ .name = "browser_type", .description = "Escribe texto en un campo editable (target {ref, snapshot_id}); mode=replace sustituye el contenido y mode=append lo añade. No escribe en campos de contraseña ni de pago.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"text":{"type":"string","minLength":0,"maxLength":8192},"mode":{"type":"string","enum":["replace","append"]}},"required":["session_id","tab_id","target","text","mode"],"additionalProperties":false}
    },
    .{ .name = "browser_key", .description = "Pulsa una tecla (Enter, Tab, Escape, flechas, Backspace o un carácter) en el elemento indicado (target) o en el que tiene el foco (view_revision). Admite Control y Shift; Alt y Meta no.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"key":{"type":"string","minLength":1,"maxLength":64},"modifiers":{"type":"array","items":{"type":"string","enum":["Alt","Control","Meta","Shift"]},"minItems":0,"maxItems":4},"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["session_id","tab_id","key","modifiers"],"additionalProperties":false}
    },
    .{ .name = "browser_scroll", .description = "Desplaza la página, o un elemento con target, dx/dy píxeles; view_revision de la última lectura.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"dx":{"type":"number","minimum":-10000,"maximum":10000},"dy":{"type":"number","minimum":-10000,"maximum":10000},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["session_id","tab_id","dy"],"additionalProperties":false}
    },
    .{ .name = "browser_hover", .description = "Mueve el ratón sobre un elemento (target {ref, snapshot_id} o {x, y, view_revision}) sin pulsar, para abrir menús o ver avisos al pasar; duration_ms es la espera tras moverlo (0-2000). Devuelve la URL, el título y la revisión de la vista.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"duration_ms":{"type":"integer","minimum":0,"maximum":2000}},"required":["session_id","tab_id","target"],"additionalProperties":false}
    },
    .{ .name = "browser_drag", .description = "Arrastra con el botón izquierdo desde from hasta to (cada uno {ref, snapshot_id} o {x, y, view_revision}) en steps movimientos intermedios (2-60, por defecto 10). Sirve para deslizadores, listas reordenables y lienzos que siguen el ratón.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"from":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"to":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"steps":{"type":"integer","minimum":2,"maximum":60}},"required":["session_id","tab_id","from","to"],"additionalProperties":false}
    },
    .{ .name = "browser_screenshot", .description = "Captura la pestaña en PNG: scope=viewport (lo visible), scope=ref (un elemento, target) o scope=rect (rect {x, y, width, height} de la vista view_revision). La imagen se guarda como archivo de evidencia de la orden y se devuelven su ruta, su tamaño en bytes y sus dimensiones.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"scope":{"type":"string","enum":["viewport","ref","rect"]},"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"rect":{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"width":{"type":"number","minimum":0.01,"maximum":2560},"height":{"type":"number","minimum":0.01,"maximum":2560}},"required":["x","y","width","height"],"additionalProperties":false},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["session_id","tab_id","scope","view_revision"],"additionalProperties":false,"oneOf":[{"properties":{"scope":{"type":"string","enum":["viewport"]}},"not":{"anyOf":[{"required":["target"]},{"required":["rect"]}]}},{"properties":{"scope":{"type":"string","enum":["ref"]}},"required":["target"],"not":{"required":["rect"]}},{"properties":{"scope":{"type":"string","enum":["rect"]}},"required":["rect"],"not":{"required":["target"]}}]}
    },
    .{ .name = "browser_zoom", .description = "Cambia el zoom de la pestaña (factor 0.5-2; 1 es el tamaño normal). Afecta a lo que ve el usuario y a las coordenadas: vuelve a leer la página después.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"factor":{"type":"number","minimum":0.5,"maximum":2}},"required":["session_id","tab_id","factor"],"additionalProperties":false}
    },
    .{ .name = "browser_fill_form", .description = "Rellena varios campos de una vez (fields, hasta 32): kind=text con value texto, kind=checkbox o radio con value true/false, kind=select con value {option_ref} (las opciones o0, o1… salen en browser_snapshot). Comprueba todos los campos antes de escribir ninguno; nunca escribe en campos de contraseña ni de pago.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"fields":{"type":"array","items":{"oneOf":[{"type":"object","properties":{"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"kind":{"type":"string","enum":["text"]},"value":{"type":"string","minLength":0,"maxLength":8192}},"required":["target","kind","value"],"additionalProperties":false},{"type":"object","properties":{"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"kind":{"type":"string","enum":["checkbox"]},"value":{"type":"boolean"}},"required":["target","kind","value"],"additionalProperties":false},{"type":"object","properties":{"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"kind":{"type":"string","enum":["radio"]},"value":{"type":"boolean"}},"required":["target","kind","value"],"additionalProperties":false},{"type":"object","properties":{"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"kind":{"type":"string","enum":["select"]},"value":{"type":"object","properties":{"option_ref":{"type":"string","minLength":1,"maxLength":256}},"required":["option_ref"],"additionalProperties":false}},"required":["target","kind","value"],"additionalProperties":false}]},"minItems":1,"maxItems":32}},"required":["session_id","tab_id","fields"],"additionalProperties":false}
    },
    .{ .name = "browser_console", .description = "Lee los mensajes de consola y los errores de JavaScript ya ocurridos en la pestaña (levels: debug, info, log, warning, error; limit hasta 100). Devuelve next_cursor para seguir leyendo desde ahí. El texto viene de la página: es contenido externo.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":5000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"cursor":{"type":"string","minLength":1,"maxLength":256},"levels":{"type":"array","items":{"type":"string","enum":["debug","info","log","warning","error"]},"minItems":1,"maxItems":5},"limit":{"type":"integer","minimum":1,"maximum":100}},"required":["session_id","tab_id"],"additionalProperties":false}
    },
    .{ .name = "browser_network", .description = "Lista las peticiones de red ya hechas por la pestaña: método, URL, estado, tipo y fallo (limit hasta 100, url_filter por subcadena, next_cursor para seguir). No incluye cuerpos ni cabeceras; los parámetros con token, key o secret y las credenciales de la URL salen como REDACTED.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":5000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"cursor":{"type":"string","minLength":1,"maxLength":256},"url_filter":{"type":"string","minLength":1,"maxLength":256},"limit":{"type":"integer","minimum":1,"maximum":100}},"required":["session_id","tab_id"],"additionalProperties":false}
    },
    .{ .name = "browser_viewport", .description = "Emula el tamaño de pantalla de la pestaña: preset mobile, tablet o desktop (desktop quita la emulación), o width, height, dpr y mobile; orientation portrait o landscape. Se deshace al cerrar la pestaña.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"preset":{"type":"string","enum":["mobile","tablet","desktop"]},"width":{"type":"integer","minimum":240,"maximum":2560},"height":{"type":"integer","minimum":240,"maximum":2560},"dpr":{"type":"number","minimum":1,"maximum":3},"mobile":{"type":"boolean"},"orientation":{"type":"string","enum":["portrait","landscape"]}},"required":["session_id","tab_id"],"additionalProperties":false,"oneOf":[{"required":["preset"],"not":{"anyOf":[{"required":["width"]},{"required":["height"]},{"required":["dpr"]},{"required":["mobile"]}]}},{"required":["width","height","dpr","mobile"],"not":{"required":["preset"]}}]}
    },
    .{ .name = "browser_color_scheme", .description = "Emula el esquema de color preferido de la pestaña (prefers-color-scheme): light, dark o system para quitar la emulación. Se deshace al cerrar la pestaña.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"mode":{"type":"string","enum":["light","dark","system"]}},"required":["session_id","tab_id","mode"],"additionalProperties":false}
    },
    .{ .name = "browser_tabs", .description = "Lista (list), crea (create, con url opcional), selecciona (select) o cierra (close) pestañas del navegador integrado.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"action":{"type":"string","enum":["create","close","select","list"]},"url":{"type":"string","minLength":1,"maxLength":8192}},"required":["session_id","action"],"additionalProperties":false,"oneOf":[{"properties":{"action":{"enum":["create"]}},"required":["url"]},{"properties":{"action":{"enum":["create"]},"timeout_ms":{"maximum":5000}},"not":{"required":["url"]}},{"properties":{"action":{"enum":["close","select"]},"timeout_ms":{"maximum":5000}},"required":["tab_id"],"not":{"required":["url"]}},{"properties":{"action":{"enum":["list"]},"timeout_ms":{"maximum":5000}},"not":{"anyOf":[{"required":["url"]},{"required":["tab_id"]}]}}]}
    },
    .{ .name = "browser_wait", .description = "Espera, con el plazo timeout_ms, a que se cumpla una condición: visible o hidden (target), text (target y expected contenido en su texto), url (expected contenido en la dirección), load (carga completa) o time (espera fija de duration_ms, al menos 1000 ms por debajo de timeout_ms). Si no se cumple a tiempo devuelve timeout.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"condition":{"type":"string","enum":["visible","hidden","text","url","load","time"]},"duration_ms":{"type":"integer","minimum":1,"maximum":30000},"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"expected":{"type":"string","minLength":1,"maxLength":4096}},"required":["session_id","tab_id","condition"],"additionalProperties":false,"oneOf":[{"properties":{"condition":{"type":"string","enum":["visible","hidden"]}},"required":["target"],"not":{"required":["expected"]}},{"properties":{"condition":{"type":"string","enum":["text"]}},"required":["target","expected"]},{"properties":{"condition":{"type":"string","enum":["url"]}},"required":["expected"],"not":{"required":["target"]}},{"properties":{"condition":{"type":"string","enum":["load"]}},"not":{"anyOf":[{"required":["target"]},{"required":["expected"]}]}},{"properties":{"condition":{"type":"string","enum":["time"]}},"required":["duration_ms"],"not":{"anyOf":[{"required":["target"]},{"required":["expected"]}]}}]}
    },
    .{ .name = "browser_batch", .description = "Ejecuta en orden hasta 32 acciones browser_* de la misma sesión (actions: [{tool, args}]), validadas enteras antes de empezar. Un target {step, ref_index} usa la referencia ref_index del snapshot o find del paso step. Para en el primer error y devuelve lo hecho hasta ahí.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":120000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"actions":{"type":"array","items":{"oneOf":[{"type":"object","properties":{"tool":{"type":"string","enum":["browser_navigate"]},"args":{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"action":{"type":"string","enum":["url","back","forward","reload","stop"]},"url":{"type":"string","minLength":1,"maxLength":8192},"wait":{"type":"string","enum":["domcontentloaded","load"]}},"required":["session_id","tab_id","action","wait"],"additionalProperties":false,"oneOf":[{"properties":{"action":{"type":"string","enum":["url"]}},"required":["url"]},{"properties":{"action":{"type":"string","enum":["back","forward","reload","stop"]}},"not":{"required":["url"]}}]}},"required":["tool","args"],"additionalProperties":false},{"type":"object","properties":{"tool":{"type":"string","enum":["browser_snapshot"]},"args":{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":5000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"frame":{"type":"string","minLength":1,"maxLength":256},"root_ref":{"type":"string","minLength":1,"maxLength":256},"cursor":{"type":"string","minLength":1,"maxLength":256}},"required":["session_id","tab_id"],"additionalProperties":false}},"required":["tool","args"],"additionalProperties":false},{"type":"object","properties":{"tool":{"type":"string","enum":["browser_find"]},"args":{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":5000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"query":{"type":"object","properties":{"role":{"type":"string","minLength":1,"maxLength":256},"name":{"type":"string","minLength":1,"maxLength":256},"text":{"type":"string","minLength":1,"maxLength":256},"exact":{"type":"boolean"}},"required":[],"additionalProperties":false,"minProperties":1},"frame":{"type":"string","minLength":1,"maxLength":256},"cursor":{"type":"string","minLength":1,"maxLength":256}},"required":["session_id","tab_id","query"],"additionalProperties":false}},"required":["tool","args"],"additionalProperties":false},{"type":"object","properties":{"tool":{"type":"string","enum":["browser_text"]},"args":{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":5000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"scope":{"type":"string","enum":["page","ref"]},"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"cursor":{"type":"string","minLength":1,"maxLength":256}},"required":["session_id","tab_id","scope"],"additionalProperties":false,"oneOf":[{"properties":{"scope":{"type":"string","enum":["page"]}},"not":{"required":["target"]}},{"properties":{"scope":{"type":"string","enum":["ref"]}},"required":["target"]}]}},"required":["tool","args"],"additionalProperties":false},{"type":"object","properties":{"tool":{"type":"string","enum":["browser_click"]},"args":{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"button":{"type":"string","enum":["left","right","middle"]},"count":{"type":"integer","minimum":1,"maximum":2}},"required":["session_id","tab_id","target","button","count"],"additionalProperties":false}},"required":["tool","args"],"additionalProperties":false},{"type":"object","properties":{"tool":{"type":"string","enum":["browser_type"]},"args":{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"text":{"type":"string","minLength":0,"maxLength":8192},"mode":{"type":"string","enum":["replace","append"]}},"required":["session_id","tab_id","target","text","mode"],"additionalProperties":false}},"required":["tool","args"],"additionalProperties":false},{"type":"object","properties":{"tool":{"type":"string","enum":["browser_key"]},"args":{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"key":{"type":"string","minLength":1,"maxLength":64},"modifiers":{"type":"array","items":{"type":"string","enum":["Alt","Control","Meta","Shift"]},"minItems":0,"maxItems":4},"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["session_id","tab_id","key","modifiers"],"additionalProperties":false,"oneOf":[{"required":["target"]},{"required":["view_revision"],"not":{"required":["target"]}}]}},"required":["tool","args"],"additionalProperties":false},{"type":"object","properties":{"tool":{"type":"string","enum":["browser_scroll"]},"args":{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"dx":{"type":"number","minimum":-10000,"maximum":10000},"dy":{"type":"number","minimum":-10000,"maximum":10000},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["session_id","tab_id","dx","dy","view_revision"],"additionalProperties":false}},"required":["tool","args"],"additionalProperties":false},{"type":"object","properties":{"tool":{"type":"string","enum":["browser_hover"]},"args":{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"duration_ms":{"type":"integer","minimum":0,"maximum":2000}},"required":["session_id","tab_id","target"],"additionalProperties":false}},"required":["tool","args"],"additionalProperties":false},{"type":"object","properties":{"tool":{"type":"string","enum":["browser_drag"]},"args":{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"from":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"to":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"steps":{"type":"integer","minimum":2,"maximum":60}},"required":["session_id","tab_id","from","to"],"additionalProperties":false}},"required":["tool","args"],"additionalProperties":false},{"type":"object","properties":{"tool":{"type":"string","enum":["browser_screenshot"]},"args":{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"scope":{"type":"string","enum":["viewport","ref","rect"]},"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"rect":{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"width":{"type":"number","minimum":0.01,"maximum":2560},"height":{"type":"number","minimum":0.01,"maximum":2560}},"required":["x","y","width","height"],"additionalProperties":false},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["session_id","tab_id","scope","view_revision"],"additionalProperties":false,"oneOf":[{"properties":{"scope":{"type":"string","enum":["viewport"]}},"not":{"anyOf":[{"required":["target"]},{"required":["rect"]}]}},{"properties":{"scope":{"type":"string","enum":["ref"]}},"required":["target"],"not":{"required":["rect"]}},{"properties":{"scope":{"type":"string","enum":["rect"]}},"required":["rect"],"not":{"required":["target"]}}]}},"required":["tool","args"],"additionalProperties":false},{"type":"object","properties":{"tool":{"type":"string","enum":["browser_zoom"]},"args":{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"factor":{"type":"number","minimum":0.5,"maximum":2}},"required":["session_id","tab_id","factor"],"additionalProperties":false}},"required":["tool","args"],"additionalProperties":false},{"type":"object","properties":{"tool":{"type":"string","enum":["browser_fill_form"]},"args":{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"fields":{"type":"array","items":{"oneOf":[{"type":"object","properties":{"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"kind":{"type":"string","enum":["text"]},"value":{"type":"string","minLength":0,"maxLength":8192}},"required":["target","kind","value"],"additionalProperties":false},{"type":"object","properties":{"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"kind":{"type":"string","enum":["checkbox"]},"value":{"type":"boolean"}},"required":["target","kind","value"],"additionalProperties":false},{"type":"object","properties":{"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"kind":{"type":"string","enum":["radio"]},"value":{"type":"boolean"}},"required":["target","kind","value"],"additionalProperties":false},{"type":"object","properties":{"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"kind":{"type":"string","enum":["select"]},"value":{"type":"object","properties":{"option_ref":{"type":"string","minLength":1,"maxLength":256}},"required":["option_ref"],"additionalProperties":false}},"required":["target","kind","value"],"additionalProperties":false}]},"minItems":1,"maxItems":32}},"required":["session_id","tab_id","fields"],"additionalProperties":false}},"required":["tool","args"],"additionalProperties":false},{"type":"object","properties":{"tool":{"type":"string","enum":["browser_console"]},"args":{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":5000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"cursor":{"type":"string","minLength":1,"maxLength":256},"levels":{"type":"array","items":{"type":"string","enum":["debug","info","log","warning","error"]},"minItems":1,"maxItems":5},"limit":{"type":"integer","minimum":1,"maximum":100}},"required":["session_id","tab_id"],"additionalProperties":false}},"required":["tool","args"],"additionalProperties":false},{"type":"object","properties":{"tool":{"type":"string","enum":["browser_network"]},"args":{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":5000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"cursor":{"type":"string","minLength":1,"maxLength":256},"url_filter":{"type":"string","minLength":1,"maxLength":256},"limit":{"type":"integer","minimum":1,"maximum":100}},"required":["session_id","tab_id"],"additionalProperties":false}},"required":["tool","args"],"additionalProperties":false},{"type":"object","properties":{"tool":{"type":"string","enum":["browser_viewport"]},"args":{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"preset":{"type":"string","enum":["mobile","tablet","desktop"]},"width":{"type":"integer","minimum":240,"maximum":2560},"height":{"type":"integer","minimum":240,"maximum":2560},"dpr":{"type":"number","minimum":1,"maximum":3},"mobile":{"type":"boolean"},"orientation":{"type":"string","enum":["portrait","landscape"]}},"required":["session_id","tab_id"],"additionalProperties":false,"oneOf":[{"required":["preset"],"not":{"anyOf":[{"required":["width"]},{"required":["height"]},{"required":["dpr"]},{"required":["mobile"]}]}},{"required":["width","height","dpr","mobile"],"not":{"required":["preset"]}}]}},"required":["tool","args"],"additionalProperties":false},{"type":"object","properties":{"tool":{"type":"string","enum":["browser_color_scheme"]},"args":{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"mode":{"type":"string","enum":["light","dark","system"]}},"required":["session_id","tab_id","mode"],"additionalProperties":false}},"required":["tool","args"],"additionalProperties":false},{"type":"object","properties":{"tool":{"type":"string","enum":["browser_tabs"]},"args":{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"action":{"type":"string","enum":["create","close","select","list"]},"url":{"type":"string","minLength":1,"maxLength":8192}},"required":["session_id","action"],"additionalProperties":false,"oneOf":[{"properties":{"action":{"enum":["create"]}},"required":["url"]},{"properties":{"action":{"enum":["create"]},"timeout_ms":{"maximum":5000}},"not":{"required":["url"]}},{"properties":{"action":{"enum":["close","select"]},"timeout_ms":{"maximum":5000}},"required":["tab_id"],"not":{"required":["url"]}},{"properties":{"action":{"enum":["list"]},"timeout_ms":{"maximum":5000}},"not":{"anyOf":[{"required":["url"]},{"required":["tab_id"]}]}}]}},"required":["tool","args"],"additionalProperties":false},{"type":"object","properties":{"tool":{"type":"string","enum":["browser_wait"]},"args":{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":30000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"condition":{"type":"string","enum":["visible","hidden","text","url","load","time"]},"duration_ms":{"type":"integer","minimum":1,"maximum":30000},"target":{"oneOf":[{"type":"object","properties":{"ref":{"type":"string","minLength":1,"maxLength":256},"snapshot_id":{"type":"string","minLength":1,"maxLength":256}},"required":["ref","snapshot_id"],"additionalProperties":false},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":2560},"y":{"type":"number","minimum":0,"maximum":2560},"view_revision":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["x","y","view_revision"],"additionalProperties":false},{"type":"object","properties":{"step":{"type":"integer","minimum":0,"maximum":31},"ref_index":{"type":"integer","minimum":0,"maximum":99}},"required":["step","ref_index"],"additionalProperties":false}]},"expected":{"type":"string","minLength":1,"maxLength":4096}},"required":["session_id","tab_id","condition"],"additionalProperties":false,"oneOf":[{"properties":{"condition":{"type":"string","enum":["visible","hidden"]}},"required":["target"],"not":{"required":["expected"]}},{"properties":{"condition":{"type":"string","enum":["text"]}},"required":["target","expected"]},{"properties":{"condition":{"type":"string","enum":["url"]}},"required":["expected"],"not":{"required":["target"]}},{"properties":{"condition":{"type":"string","enum":["load"]}},"not":{"anyOf":[{"required":["target"]},{"required":["expected"]}]}},{"properties":{"condition":{"type":"string","enum":["time"]}},"required":["duration_ms"],"not":{"anyOf":[{"required":["target"]},{"required":["expected"]}]}}]}},"required":["tool","args"],"additionalProperties":false}]},"minItems":1,"maxItems":32}},"required":["session_id","tab_id","actions"],"additionalProperties":false}
    },
    .{ .name = "browser_debug_js", .description = "Evalúa JavaScript (code) para depurar la página aprobada y devuelve el valor de la última expresión como texto. Corre aparte del script de la página: no puede leer ni escribir campos de contraseña o de pago, enviar formularios saltándose la página ni abrir otras ventanas. Se registra que se usó, nunca el código.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":2000},"session_id":{"type":"string","minLength":1,"maxLength":256},"tab_id":{"type":"string","minLength":1,"maxLength":256},"code":{"type":"string","minLength":1,"maxLength":32768}},"required":["session_id","tab_id","code"],"additionalProperties":false}
    },
    .{ .name = "app_server_start", .description = "Arranca el servidor de desarrollo del proyecto por el nombre de su configuración (configuration) en .devagents/launch.json o .claude/launch.json (runtimeExecutable, runtimeArgs, port). El comando pasa por la misma aprobación que run_command, escucha en 127.0.0.1 y se para al terminar la orden. Devuelve server_id, lease_generation y la URL.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":120000},"configuration":{"type":"string","minLength":1,"maxLength":256}},"required":["configuration"],"additionalProperties":false}
    },
    .{ .name = "app_server_stop", .description = "Para un servidor de desarrollo arrancado con app_server_start (server_id y lease_generation que devolvió) y todo su árbol de procesos.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":20000},"server_id":{"type":"string","minLength":1,"maxLength":256},"lease_generation":{"type":"integer","minimum":1,"maximum":9007199254740991}},"required":["server_id","lease_generation"],"additionalProperties":false}
    },
    .{ .name = "app_server_logs", .description = "Lee la salida de un servidor de desarrollo arrancado con app_server_start: stream stdout, stderr o both, desde cursor (next_cursor de la lectura anterior), hasta limit_bytes. Lo más antiguo se descarta si supera el registro acotado.", .parameters_json =
    \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":5000},"server_id":{"type":"string","minLength":1,"maxLength":256},"cursor":{"type":"string","minLength":1,"maxLength":256},"stream":{"type":"string","enum":["stdout","stderr","both"]},"limit_bytes":{"type":"integer","minimum":1,"maximum":65536}},"required":["server_id","stream"],"additionalProperties":false}
    },
};

pub fn find(name: []const u8) ?providers.connector_v2.ToolDefinition {
    for (CATALOG) |tool| if (std.mem.eql(u8, name, tool.name)) return tool;
    return null;
}

pub fn isBrowserTool(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "browser_") or std.mem.startsWith(u8, name, "app_server_");
}

pub const Validated = struct {
    parsed: std.json.Parsed(std.json.Value),
    timeout_ms: u32,

    pub fn deinit(self: *Validated) void {
        self.parsed.deinit();
    }
};

/// Validation is local and mandatory even if the provider enforces schemas.
pub fn validate(a: std.mem.Allocator, name: []const u8, arguments: []const u8) !Validated {
    const tool = find(name) orelse return error.UnsupportedTool;
    if (arguments.len > MAX_ARGUMENT_BYTES) return error.LimitExceeded;
    if (!std.unicode.utf8ValidateSlice(arguments)) return error.InvalidArguments;
    var parsed = std.json.parseFromSlice(std.json.Value, a, arguments, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidArguments,
    };
    errdefer parsed.deinit();
    var schema = try std.json.parseFromSlice(std.json.Value, a, tool.parameters_json, .{});
    defer schema.deinit();
    try validateValue(schema.value, parsed.value, 0);
    try validateSemantics(name, parsed.value, null);
    const timeout: u32 = if (parsed.value.object.get("timeout_ms")) |v| @intCast(v.integer) else if (std.mem.eql(u8, name, "browser_tabs") and parsed.value.object.contains("url")) 10000 else defaultTimeout(name);
    return .{ .parsed = parsed, .timeout_ms = timeout };
}

pub fn defaultTimeout(name: []const u8) u32 {
    if (std.mem.eql(u8, name, "browser_debug_js")) return 2000;
    if (std.mem.eql(u8, name, "app_server_stop")) return 20000;
    if (std.mem.eql(u8, name, "app_server_start")) return 30000;
    if (std.mem.eql(u8, name, "browser_batch")) return 120000;
    for ([_][]const u8{ "browser_snapshot", "browser_find", "browser_text", "browser_console", "browser_network", "browser_tabs", "app_server_logs" }) |read| {
        if (std.mem.eql(u8, name, read)) return 5000;
    }
    return 10000;
}

fn numeric(value: std.json.Value) !f64 {
    return switch (value) {
        .integer => @floatFromInt(value.integer),
        .float => if (std.math.isFinite(value.float)) value.float else error.InvalidArguments,
        else => error.InvalidArguments,
    };
}

// Restricted JSON-schema vocabulary used by CATALOG. Fail closed on types,
// recursively closed objects, exclusive alternatives, ranges and UTF-8 bytes.
fn validateValue(schema: std.json.Value, value: std.json.Value, depth: usize) error{ InvalidArguments, LimitExceeded }!void {
    if (depth > 32) return error.LimitExceeded;
    const s = schema.object;
    if (s.get("type")) |kind| {
        const valid = if (std.mem.eql(u8, kind.string, "object")) value == .object else if (std.mem.eql(u8, kind.string, "array")) value == .array else if (std.mem.eql(u8, kind.string, "string")) value == .string else if (std.mem.eql(u8, kind.string, "boolean")) value == .bool else if (std.mem.eql(u8, kind.string, "integer")) value == .integer else if (std.mem.eql(u8, kind.string, "number")) value == .integer or value == .float else false;
        if (!valid) return error.InvalidArguments;
    }
    if (s.get("enum")) |values| {
        var matched = false;
        for (values.array.items) |choice| {
            if (value == .string and std.mem.eql(u8, value.string, choice.string)) matched = true;
        }
        if (!matched) return error.InvalidArguments;
    }
    if (value == .object) {
        if (s.get("required")) |required| for (required.array.items) |key| {
            if (!value.object.contains(key.string)) return error.InvalidArguments;
        };
        if (s.get("minProperties")) |minimum| if (value.object.count() < minimum.integer) return error.InvalidArguments;
        if (s.get("properties")) |properties| {
            var it = value.object.iterator();
            while (it.next()) |entry| {
                if (properties.object.get(entry.key_ptr.*)) |property| {
                    try validateValue(property, entry.value_ptr.*, depth + 1);
                } else if (s.get("additionalProperties")) |allow| {
                    if (!allow.bool) return error.InvalidArguments;
                }
            }
        }
    }
    if (value == .string) {
        if (!std.unicode.utf8ValidateSlice(value.string) or std.mem.indexOfScalar(u8, value.string, 0) != null) return error.InvalidArguments;
        if (s.get("minLength")) |minimum| if (value.string.len < minimum.integer) return error.InvalidArguments;
        if (s.get("maxLength")) |maximum| if (value.string.len > maximum.integer) return error.LimitExceeded;
    }
    if (value == .array) {
        if (s.get("minItems")) |minimum| if (value.array.items.len < minimum.integer) return error.InvalidArguments;
        if (s.get("maxItems")) |maximum| if (value.array.items.len > maximum.integer) return error.LimitExceeded;
        if (s.get("items")) |item_schema| for (value.array.items) |item| try validateValue(item_schema, item, depth + 1);
    }
    if (value == .integer or value == .float) {
        const n = try numeric(value);
        if (s.get("minimum")) |minimum| if (n < try numeric(minimum)) return error.LimitExceeded;
        if (s.get("maximum")) |maximum| if (n > try numeric(maximum)) return error.LimitExceeded;
    }
    for ([_][]const u8{ "oneOf", "anyOf" }) |keyword| if (s.get(keyword)) |alternatives| {
        var matches: usize = 0;
        for (alternatives.array.items) |alternative| {
            validateValue(alternative, value, depth + 1) catch continue;
            matches += 1;
        }
        if (matches == 0 or (std.mem.eql(u8, keyword, "oneOf") and matches != 1)) return error.InvalidArguments;
    };
    if (s.get("not")) |forbidden| {
        validateValue(forbidden, value, depth + 1) catch return;
        return error.InvalidArguments;
    }
}

fn validateLinks(value: std.json.Value, previous_steps: ?[]const std.json.Value, depth: usize) !void {
    if (depth > 32) return error.LimitExceeded;
    if (value == .object) {
        if (value.object.get("step")) |step| {
            const producers = previous_steps orelse return error.InvalidArguments;
            if (step != .integer or step.integer < 0 or step.integer >= producers.len) return error.InvalidArguments;
            const producer = producers[@intCast(step.integer)].object.get("tool").?.string;
            if (!std.mem.eql(u8, producer, "browser_snapshot") and !std.mem.eql(u8, producer, "browser_find")) return error.InvalidArguments;
        }
        var it = value.object.iterator();
        while (it.next()) |entry| try validateLinks(entry.value_ptr.*, previous_steps, depth + 1);
    } else if (value == .array) {
        for (value.array.items) |item| try validateLinks(item, previous_steps, depth + 1);
    }
}

fn validateSemantics(name: []const u8, value: std.json.Value, previous_steps: ?[]const std.json.Value) !void {
    const v = value.object;
    if (std.mem.eql(u8, name, "browser_batch")) {
        const session = v.get("session_id").?.string;
        var screenshots: usize = 0;
        const actions = v.get("actions").?.array.items;
        for (actions, 0..) |step, index| {
            const args = step.object.get("args").?;
            if (!std.mem.eql(u8, args.object.get("session_id").?.string, session)) return error.InvalidArguments;
            const tool = step.object.get("tool").?.string;
            if (std.mem.eql(u8, tool, "browser_screenshot")) screenshots += 1;
            try validateSemantics(tool, args, actions[0..index]);
        }
        if (screenshots > 4) return error.LimitExceeded;
        return;
    }
    try validateLinks(value, previous_steps, 0);
    if (std.mem.eql(u8, name, "browser_find")) {
        const q = v.get("query").?.object;
        if (!q.contains("role") and !q.contains("name") and !q.contains("text")) return error.InvalidArguments;
        var bytes: usize = 0;
        for ([_][]const u8{ "role", "name", "text" }) |field| if (q.get(field)) |text| {
            bytes += text.string.len;
        };
        if (bytes > 256) return error.LimitExceeded;
    }
    if (std.mem.eql(u8, name, "browser_key")) {
        var bytes = v.get("key").?.string.len;
        for (v.get("modifiers").?.array.items) |modifier| bytes += modifier.string.len + 1;
        if (bytes > 64) return error.LimitExceeded;
    }
    if (std.mem.eql(u8, name, "browser_fill_form")) {
        var total: usize = 0;
        for (v.get("fields").?.array.items) |field| {
            const val = field.object.get("value").?;
            if (val == .string) total += val.string.len;
        }
        if (total > 16 * 1024) return error.LimitExceeded;
    }
    if (std.mem.eql(u8, name, "browser_wait")) {
        // T6: duration_ms solo con condition=time, y con un segundo de margen
        // dentro del plazo de la petición (si no, siempre acabaría en timeout).
        const timed = std.mem.eql(u8, v.get("condition").?.string, "time");
        if (v.get("duration_ms")) |duration| {
            if (!timed) return error.InvalidArguments;
            const limit: i64 = if (v.get("timeout_ms")) |t| t.integer else defaultTimeout(name);
            if (duration.integer + 1000 > limit) return error.LimitExceeded;
        }
    }
    if (std.mem.eql(u8, name, "browser_viewport") and v.contains("width")) {
        const pixels = try numeric(v.get("width").?) * try numeric(v.get("height").?) * std.math.pow(f64, try numeric(v.get("dpr").?), 2);
        if (pixels > 8_000_000) return error.LimitExceeded;
    }
}

const VALID_EXAMPLES = [_][]const u8{
    "{\"action\":\"url\",\"url\":\"http://127.0.0.1:8123/\",\"wait\":\"load\",\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"query\":{\"role\":\"button\",\"name\":\"Calculate\"},\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"scope\":\"page\",\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"target\":{\"ref\":\"r1\",\"snapshot_id\":\"snap1\"},\"button\":\"left\",\"count\":1,\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"target\":{\"ref\":\"r1\",\"snapshot_id\":\"snap1\"},\"text\":\"6\",\"mode\":\"replace\",\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"key\":\"Enter\",\"modifiers\":[],\"view_revision\":1,\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"dx\":0,\"dy\":300,\"view_revision\":1,\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"target\":{\"ref\":\"r1\",\"snapshot_id\":\"snap1\"},\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"from\":{\"ref\":\"r1\",\"snapshot_id\":\"snap1\"},\"to\":{\"x\":20,\"y\":30,\"view_revision\":1},\"steps\":10,\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"scope\":\"rect\",\"rect\":{\"x\":0,\"y\":0,\"width\":100,\"height\":100},\"view_revision\":1,\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"factor\":1.25,\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"fields\":[{\"target\":{\"ref\":\"r1\",\"snapshot_id\":\"snap1\"},\"kind\":\"checkbox\",\"value\":true}],\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"levels\":[\"error\"],\"limit\":100,\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"limit\":100,\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"width\":1280,\"height\":800,\"dpr\":1,\"mobile\":false,\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"mode\":\"dark\",\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"action\":\"list\",\"session_id\":\"s\"}",
    "{\"condition\":\"visible\",\"target\":{\"ref\":\"r1\",\"snapshot_id\":\"snap1\"},\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"actions\":[{\"tool\":\"browser_snapshot\",\"args\":{\"session_id\":\"s\",\"tab_id\":\"t\"}},{\"tool\":\"browser_click\",\"args\":{\"session_id\":\"s\",\"tab_id\":\"t\",\"target\":{\"step\":0,\"ref_index\":0},\"button\":\"left\",\"count\":1}}],\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"code\":\"document.title\",\"session_id\":\"s\",\"tab_id\":\"t\"}",
    "{\"configuration\":\"dev\"}",
    "{\"server_id\":\"server1\",\"lease_generation\":1}",
    "{\"server_id\":\"server1\",\"stream\":\"both\",\"limit_bytes\":65536}",
};

test "E2P1 all 24 strict schemas accept fixtures and reject forged identity fields" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 24), CATALOG.len);
    for (CATALOG, VALID_EXAMPLES) |tool, args| {
        var valid = try validate(a, tool.name, args);
        defer valid.deinit();
        try valid.parsed.value.object.put(valid.parsed.arena.allocator(), "order_id", .{ .integer = 999 });
        const forged = try std.json.Stringify.valueAlloc(a, valid.parsed.value, .{});
        defer a.free(forged);
        try std.testing.expectError(error.InvalidArguments, validate(a, tool.name, forged));
    }
    std.debug.print("E2P1 SCHEMAS accepted={d} forged_identity_rejected={d}\n", .{ CATALOG.len, CATALOG.len });
    try std.testing.expect(find("browser_snapshot") != null);
    try std.testing.expect(find("browser_unknown") == null);
    try std.testing.expect(isBrowserTool("app_server_logs"));
    try std.testing.expect(!isBrowserTool("run_command"));
    try std.testing.expectError(error.UnsupportedTool, validate(a, "browser_unknown", "{}"));
}

test "T6 every catalog tool carries a real Spanish description, never its own name" {
    // 13-nov: 15 herramientas llevaban de descripción su propio nombre
    // («browser hover»); el modelo no sabía para qué servían.
    for (CATALOG) |tool| {
        var placeholder: [64]u8 = undefined;
        const spaced = placeholder[0..tool.name.len];
        @memcpy(spaced, tool.name);
        std.mem.replaceScalar(u8, spaced, '_', ' ');
        try std.testing.expect(!std.ascii.eqlIgnoreCase(tool.description, spaced));
        try std.testing.expect(tool.description.len >= 80);
        try std.testing.expect(std.unicode.utf8ValidateSlice(tool.description));
    }
}

test "T6 browser_wait accepts a fixed time wait only with duration_ms inside its deadline" {
    const a = std.testing.allocator;
    var timed = try validate(a, "browser_wait", "{\"session_id\":\"s\",\"tab_id\":\"t\",\"condition\":\"time\",\"duration_ms\":2000}");
    timed.deinit();
    var long = try validate(a, "browser_wait", "{\"session_id\":\"s\",\"tab_id\":\"t\",\"condition\":\"time\",\"duration_ms\":20000,\"timeout_ms\":21000}");
    long.deinit();
    try std.testing.expectError(error.InvalidArguments, validate(a, "browser_wait", "{\"session_id\":\"s\",\"tab_id\":\"t\",\"condition\":\"time\"}"));
    try std.testing.expectError(error.InvalidArguments, validate(a, "browser_wait", "{\"session_id\":\"s\",\"tab_id\":\"t\",\"condition\":\"load\",\"duration_ms\":100}"));
    try std.testing.expectError(error.InvalidArguments, validate(a, "browser_wait", "{\"session_id\":\"s\",\"tab_id\":\"t\",\"condition\":\"time\",\"duration_ms\":100,\"expected\":\"x\"}"));
    try std.testing.expectError(error.LimitExceeded, validate(a, "browser_wait", "{\"session_id\":\"s\",\"tab_id\":\"t\",\"condition\":\"time\",\"duration_ms\":9500}"));
    try std.testing.expectError(error.LimitExceeded, validate(a, "browser_wait", "{\"session_id\":\"s\",\"tab_id\":\"t\",\"condition\":\"time\",\"duration_ms\":30001,\"timeout_ms\":30000}"));
}

test "E2P1 strict nested schemas and incompatible alternatives fail closed" {
    const cases = [_]struct { name: []const u8, args: []const u8 }{
        .{ .name = "browser_snapshot", .args = "[]" },
        .{ .name = "browser_snapshot", .args = "{\"session_id\":\"s\",\"session_id\":\"forged\",\"tab_id\":\"t\"}" },
        .{ .name = "browser_find", .args = "{\"session_id\":\"s\",\"tab_id\":\"t\",\"query\":{\"exact\":true}}" },
        .{ .name = "browser_click", .args = "{\"session_id\":\"s\",\"tab_id\":\"t\",\"target\":{\"ref\":\"r\",\"snapshot_id\":\"n\",\"selector\":\"#secret\"},\"button\":\"left\",\"count\":1}" },
        .{ .name = "browser_click", .args = "{\"session_id\":\"s\",\"tab_id\":\"t\",\"target\":{\"step\":0,\"ref_index\":0},\"button\":\"left\",\"count\":1}" },
        .{ .name = "browser_navigate", .args = "{\"session_id\":\"s\",\"tab_id\":\"t\",\"action\":\"back\",\"wait\":\"load\",\"url\":\"https://example.test\"}" },
        .{ .name = "browser_debug_js", .args = "{\"session_id\":\"s\",\"tab_id\":\"t\",\"probe\":\"title\"}" },
        .{ .name = "browser_fill_form", .args = "{\"session_id\":\"s\",\"tab_id\":\"t\",\"fields\":[{\"target\":{\"ref\":\"r\",\"snapshot_id\":\"n\"},\"kind\":\"checkbox\",\"value\":\"true\"}]}" },
        .{ .name = "browser_viewport", .args = "{\"session_id\":\"s\",\"tab_id\":\"t\",\"preset\":\"mobile\",\"width\":390}" },
        .{ .name = "browser_batch", .args = "{\"session_id\":\"s\",\"tab_id\":\"t\",\"actions\":[{\"tool\":\"browser_debug_js\",\"args\":{\"session_id\":\"s\",\"tab_id\":\"t\",\"code\":\"document.title\"}}]}" },
        .{ .name = "browser_batch", .args = "{\"session_id\":\"s\",\"tab_id\":\"t\",\"actions\":[{\"tool\":\"browser_click\",\"args\":{\"session_id\":\"s\",\"tab_id\":\"t\",\"target\":{\"step\":0,\"ref_index\":0},\"button\":\"left\",\"count\":1}}]}" },
    };
    for (cases) |case| try std.testing.expectError(error.InvalidArguments, validate(std.testing.allocator, case.name, case.args));
    try std.testing.expectError(error.LimitExceeded, validate(std.testing.allocator, "browser_zoom", "{\"session_id\":\"s\",\"tab_id\":\"t\",\"factor\":2.1}"));
    try std.testing.expectError(error.LimitExceeded, validate(std.testing.allocator, "browser_viewport", "{\"session_id\":\"s\",\"tab_id\":\"t\",\"width\":2560,\"height\":2560,\"dpr\":3,\"mobile\":true}"));
    try std.testing.expectError(error.LimitExceeded, validate(std.testing.allocator, "browser_snapshot", "{\"session_id\":\"s\",\"tab_id\":\"t\",\"timeout_ms\":5001}"));
    const large = try std.testing.allocator.alloc(u8, MAX_ARGUMENT_BYTES + 1);
    defer std.testing.allocator.free(large);
    @memset(large, ' ');
    try std.testing.expectError(error.LimitExceeded, validate(std.testing.allocator, "browser_snapshot", large));
}

test "E2P1B batch references require snapshot or find producers for every target" {
    const a = std.testing.allocator;
    const consumers = [_][]const u8{
        \\{"tool":"browser_text","args":{"session_id":"s","tab_id":"t","scope":"ref","target":{"step":0,"ref_index":0}}}
        ,
        \\{"tool":"browser_click","args":{"session_id":"s","tab_id":"t","button":"left","count":1,"target":{"step":0,"ref_index":0}}}
        ,
        \\{"tool":"browser_type","args":{"session_id":"s","tab_id":"t","text":"6","mode":"replace","target":{"step":0,"ref_index":0}}}
        ,
        \\{"tool":"browser_key","args":{"session_id":"s","tab_id":"t","key":"Enter","modifiers":[],"target":{"step":0,"ref_index":0}}}
        ,
        \\{"tool":"browser_scroll","args":{"session_id":"s","tab_id":"t","dx":0,"dy":10,"view_revision":1,"target":{"step":0,"ref_index":0}}}
        ,
        \\{"tool":"browser_hover","args":{"session_id":"s","tab_id":"t","target":{"step":0,"ref_index":0}}}
        ,
        \\{"tool":"browser_drag","args":{"session_id":"s","tab_id":"t","from":{"step":0,"ref_index":0},"to":{"ref":"r","snapshot_id":"n"}}}
        ,
        \\{"tool":"browser_drag","args":{"session_id":"s","tab_id":"t","from":{"ref":"r","snapshot_id":"n"},"to":{"step":0,"ref_index":0}}}
        ,
        \\{"tool":"browser_screenshot","args":{"session_id":"s","tab_id":"t","scope":"ref","view_revision":1,"target":{"step":0,"ref_index":0}}}
        ,
        \\{"tool":"browser_fill_form","args":{"session_id":"s","tab_id":"t","fields":[{"kind":"text","value":"6","target":{"step":0,"ref_index":0}}]}}
        ,
        \\{"tool":"browser_wait","args":{"session_id":"s","tab_id":"t","condition":"visible","target":{"step":0,"ref_index":0}}}
        ,
    };
    var accepted: usize = 0;
    var rejected: usize = 0;
    // Start with el segundo auditor's click regression, then cover every permitted batch action.
    for ([_]usize{ 4, 0, 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 }) |producer_index| {
        const producer = CATALOG[producer_index];
        const args = VALID_EXAMPLES[producer_index];
        for (consumers) |consumer| {
            const batch = try std.fmt.allocPrint(a, "{{\"session_id\":\"s\",\"tab_id\":\"t\",\"actions\":[{{\"tool\":\"{s}\",\"args\":{s}}},{s}]}}", .{ producer.name, args, consumer });
            defer a.free(batch);
            if (std.mem.eql(u8, producer.name, "browser_snapshot") or std.mem.eql(u8, producer.name, "browser_find")) {
                var valid = try validate(a, "browser_batch", batch);
                valid.deinit();
                accepted += 1;
            } else {
                if (validate(a, "browser_batch", batch)) |validated| {
                    var unexpected = validated;
                    unexpected.deinit();
                    std.debug.print("E2P1B INVALID_PRODUCER_ACCEPTED={s} consumer={s}\n", .{ producer.name, consumer });
                    return error.TestExpectedError;
                } else |err| {
                    try std.testing.expectEqual(error.InvalidArguments, err);
                }
                rejected += 1;
            }
        }
    }
    std.debug.print("E2P1B LINKS accepted={d} invalid_producer_rejected={d}\n", .{ accepted, rejected });
}

test "E2P1 aggregate query chord form and batch budgets are bounded" {
    const a = std.testing.allocator;
    var text: [8192]u8 = @splat('x');
    const find_args = try std.json.Stringify.valueAlloc(a, .{ .session_id = "s", .tab_id = "t", .query = .{ .role = text[0..200], .name = text[0..200] } }, .{});
    defer a.free(find_args);
    try std.testing.expectError(error.LimitExceeded, validate(a, "browser_find", find_args));
    const chord = try std.json.Stringify.valueAlloc(a, .{ .session_id = "s", .tab_id = "t", .key = text[0..64], .modifiers = [_][]const u8{"Shift"}, .view_revision = 1 }, .{});
    defer a.free(chord);
    try std.testing.expectError(error.LimitExceeded, validate(a, "browser_key", chord));
    const field = .{ .target = .{ .ref = "r", .snapshot_id = "n" }, .kind = "text", .value = text[0..] };
    const form = try std.json.Stringify.valueAlloc(a, .{ .session_id = "s", .tab_id = "t", .fields = .{ field, field, field } }, .{});
    defer a.free(form);
    try std.testing.expectError(error.LimitExceeded, validate(a, "browser_fill_form", form));
    const shot = .{ .tool = "browser_screenshot", .args = .{ .session_id = "s", .tab_id = "t", .scope = "viewport", .view_revision = 1 } };
    const batch = try std.json.Stringify.valueAlloc(a, .{ .session_id = "s", .tab_id = "t", .actions = .{ shot, shot, shot, shot, shot } }, .{});
    defer a.free(batch);
    try std.testing.expectError(error.LimitExceeded, validate(a, "browser_batch", batch));
}
