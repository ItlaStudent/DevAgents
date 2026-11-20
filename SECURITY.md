# Seguridad / Security

[Español](#español) · [English](#english)

## Español

DevAgents ejecuta agentes que leen archivos, escriben y lanzan comandos en tu equipo, así que la seguridad es parte del producto: carpetas confinadas, permisos por herramienta, claves cifradas con DPAPI y un detector de secretos en cada commit.

### Versiones con soporte

Solo la última versión de `main`. Mientras DevAgents esté en beta no hay ramas de mantenimiento.

### Cómo avisar de una vulnerabilidad

**No abras una incidencia pública.** Usa el aviso de seguridad privado del repositorio (*Security › Report a vulnerability*). Incluye:

- qué componente está afectado (motor, cabina, servidor MCP, un adaptador de proveedor…);
- los pasos para reproducirlo y su impacto;
- la versión (barra de estado o `devagents-core.exe --version`).

Respondemos en un máximo de 7 días con una primera valoración. Cuando haya arreglo, se publica la corrección y, si quieres, te damos crédito en las notas.

### Qué entra

- Escapar de la carpeta de trabajo elegida o de un *space*.
- Ejecutar comandos o escribir archivos saltándose los permisos o la aprobación.
- Exponer claves de API, tokens o datos de sesiones.
- Tomar el control de la cabina desde una página web, un archivo del proyecto o la respuesta de un modelo (inyección de instrucciones que se convierte en acción).

Lo que haga un modelo **dentro** de los permisos que le diste no es una vulnerabilidad de DevAgents; un fallo de los permisos sí lo es.

---

## English

DevAgents runs agents that read files, write and run commands on your machine, so security is part of the product: confined folders, per-tool permissions, keys encrypted with DPAPI and a secrets detector on every commit.

### Supported versions

Only the latest `main`. While DevAgents is in beta there are no maintenance branches.

### Reporting a vulnerability

**Do not open a public issue.** Use the repository's private security advisory (*Security › Report a vulnerability*). Please include:

- the affected component (engine, app, MCP server, a provider adapter…);
- steps to reproduce and the impact;
- the version (status bar or `devagents-core.exe --version`).

We reply within 7 days with a first assessment. Once fixed, the correction is published and, if you wish, you are credited in the notes.

### In scope

- Escaping the chosen working folder or a *space*.
- Running commands or writing files while bypassing permissions or approval.
- Exposing API keys, tokens or session data.
- Taking over the app from a web page, a project file or a model's reply (prompt injection that turns into action).

What a model does **within** the permissions you granted is not a DevAgents vulnerability; a failure of those permissions is.
