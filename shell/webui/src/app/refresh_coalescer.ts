/**
 * Coalesce peticiones de refresco de una lectura cara (aquí, la lista de
 * sesiones del motor).
 *
 * Mientras hay una lectura en vuelo, una petición nueva NO lanza otra en
 * paralelo: se anota que hay una pendiente y, al terminar la actual, se corre
 * UNA sola más. Sin esto, el refresco que llega justo después de crear la orden
 * se perdía si coincidía con la revalidación en vuelo, y la fila nueva no
 * aparecía en la barra lateral hasta pulsar «Actualizar». Tampoco produce
 * ráfagas: muchas peticiones seguidas cuestan, como máximo, una lectura extra.
 */
export class RefreshCoalescer {
  private inFlight = false;
  private queued = false;

  constructor(private readonly run: () => void | Promise<void>) {}

  /** Pide un refresco. Si ya hay uno en vuelo, encola exactamente uno más. */
  public request(): void {
    if (this.inFlight) {
      this.queued = true;
      return;
    }
    this.start();
  }

  /** Hay una lectura en curso. */
  public get busy(): boolean {
    return this.inFlight;
  }

  /** Quedó una lectura encolada para cuando termine la actual. */
  public get pending(): boolean {
    return this.queued;
  }

  private start(): void {
    this.inFlight = true;
    void (async () => {
      try {
        await this.run();
      } catch {
        // El fallo de la lectura se gestiona dentro de `run` (mensaje al
        // usuario); aquí solo se coordina, así que un rechazo no debe dejar la
        // cola bloqueada.
      } finally {
        this.inFlight = false;
        if (this.queued) {
          this.queued = false;
          this.start();
        }
      }
    })();
  }
}
