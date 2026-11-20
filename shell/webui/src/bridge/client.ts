export interface BridgeMessage<T = unknown> {
  id: number;
  kind: string;
  payload: T;
}

export interface BridgeErrorResponse {
  id: number;
  error: string;
}

// Plazos por llamada. Antes no había ninguno: una petición sin respuesta
// dejaba su promesa pendiente para siempre y el panel se quedaba en
// "Consultando…" sin error visible. El plazo NO cancela la operación en el
// host (sigue y termina); lo que hace es rechazar la promesa con la causa
// real para que la UI muestre el fallo en vez de un spinner eterno.
const FAST_TIMEOUT_MS = 60_000;
const SLOW_TIMEOUT_MS = 300_000;

// Mismo criterio que `kLentas` en shell/host/main.cpp: lo que sale a la red
// puede tardar minutos legítimos; lo demás debe responder en segundos.
// Si la lista cambia allá, cambiarla aquí también.
const SLOW_KINDS = new Set([
  'core.complete',
  'core.health.probe',
  'core.vision.probe',
  'core.models.discover',
  'core.external.agents',
  'core.external.refresh',
  'core.external.options.set',
  'core.inventory.refresh',
  'core.doctor',
  'core.update.state',
  'core.update.check',
  'core.update.download',
  'core.update.setEnabled',
  'core.update.applyOnExit',
  'core.mcp.connect',
  'core.mcp.call',
  'core.mcp.tools',
  'core.model.register',
  'core.websearch',
  'core.issues.list',
  'core.issues.read',
  'core.issues.prompt',
  'core.issues.comment',
  'core.order.fromIssue',
]);

// E5.21 — difusión entre ventanas: el host emite mensajes SIN `id` con forma
// `{push:"<topic>", payload:{…}}` (doc.saved, fs.changed, …). Cualquier vista
// puede suscribirse; cada ventana recibe la copia que el supervisor difunde.
export type PushHandler = (topic: string, payload: unknown) => void;

export class BridgeClient {
  private nextId = 1;
  private pending = new Map<number, (res: unknown) => void>();
  private timers = new Map<number, ReturnType<typeof setTimeout>>();
  private pushHandlers = new Set<PushHandler>();

  /** Suscribe a eventos difundidos por el host. Devuelve el unsubscribe. */
  public onPush(handler: PushHandler): () => void {
    this.pushHandlers.add(handler);
    return () => {
      this.pushHandlers.delete(handler);
    };
  }

  constructor() {
    if (typeof window !== 'undefined' && (window as unknown as { chrome?: { webview?: { addEventListener: Function } } }).chrome?.webview) {
      (window as unknown as { chrome: { webview: { addEventListener: Function } } }).chrome.webview.addEventListener('message', (event: { data: unknown }) => {
        this.onHostMessage(event.data);
      });
    }
  }

  public send<TReq, TRes>(kind: string, payload: TReq, timeoutMs?: number): Promise<TRes> {
    const id = this.nextId++;
    const message: BridgeMessage<TReq> = { id, kind, payload };

    return new Promise<TRes>((resolve, reject) => {
      this.pending.set(id, (res) => {
        if (typeof res === 'object' && res !== null && 'error' in res) {
          reject(new Error((res as BridgeErrorResponse).error));
        } else {
          resolve(res as TRes);
        }
      });

      const plazo = timeoutMs ?? (SLOW_KINDS.has(kind) ? SLOW_TIMEOUT_MS : FAST_TIMEOUT_MS);
      this.timers.set(
        id,
        setTimeout(() => {
          if (!this.pending.delete(id)) return;
          this.timers.delete(id);
          console.error(`[BridgeClient] sin respuesta del host tras ${plazo} ms (${kind})`);
          reject(new Error(`El host no respondió a '${kind}' en ${plazo / 1000}s; la operación sigue en curso en el motor`));
        }, plazo)
      );

      if (typeof window !== 'undefined' && (window as unknown as { chrome?: { webview?: { postMessage: Function } } }).chrome?.webview) {
        (window as unknown as { chrome: { webview: { postMessage: Function } } }).chrome.webview.postMessage(JSON.stringify(message));
      } else {
        // Fallback mock for browser dev testing
        setTimeout(() => {
          this.onHostMessage({ id, status: 'ok', payload: { mock: true } });
        }, 10);
      }
    });
  }

  private onHostMessage(data: unknown) {
    let msg: BridgeMessage;
    if (typeof data === 'string') {
      try {
        msg = JSON.parse(data);
      } catch (e) {
        // Antes se hacía `return` a secas. Un mensaje ilegible dejaba su
        // promesa pendiente PARA SIEMPRE: el panel que la esperaba se quedaba
        // congelado en su bloque de carga y no aparecía ningún error en
        // ninguna parte. Al menos hay que dejar rastro.
        console.error('[BridgeClient] respuesta del host ilegible:', e, String(data).slice(0, 200));
        return;
      }
    } else {
      msg = data as BridgeMessage;
    }

    // Evento difundido (E5.21): no tiene `id` — no es respuesta a nadie.
    const pushTopic = (msg as unknown as { push?: unknown })?.push;
    if (typeof pushTopic === 'string' && pushTopic) {
      const payload = (msg as unknown as { payload?: unknown }).payload;
      for (const h of this.pushHandlers) {
        try {
          h(pushTopic, payload);
        } catch (e) {
          console.error('[BridgeClient] handler de push falló:', e);
        }
      }
      return;
    }

    if (msg && typeof msg.id === 'number') {
      const handler = this.pending.get(msg.id);
      if (handler) {
        this.pending.delete(msg.id);
        const t = this.timers.get(msg.id);
        if (t !== undefined) {
          clearTimeout(t);
          this.timers.delete(msg.id);
        }
        handler(msg);
      }
    }
  }
}
