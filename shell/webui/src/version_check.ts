import type { CoreApi } from './bridge/core_api';

declare const __DEVAGENTS_BUILD_IDENTITY__: string;
export const buildIdentity = typeof __DEVAGENTS_BUILD_IDENTITY__ === 'string'
  ? __DEVAGENTS_BUILD_IDENTITY__ : 'unpackaged/abi1.bus1.ui1';

export function versionMismatch(piece: string, expected: string, found: string): string {
  // Match the host policy: Git-less builds remain buildable but cannot pass startup.
  const hasGitIdentity = (identity: string): boolean => /^[^+]+\+[0-9a-fA-F]{7,64}\/.+$/.test(identity);
  const identified = hasGitIdentity(expected) && hasGitIdentity(found);
  return identified && expected === found ? '' : `Version incompatible de ${piece}: host esperaba ${expected}; encontro ${found || 'ausente (sin version)'}.${identified ? '' : ' build sin identidad de git.'} Actualiza ${piece} y el host desde el mismo paquete DevAgents.`;
}

export function showVersionError(message: string, target: HTMLElement = document.body): void {
  const warning = document.createElement('section');
  warning.setAttribute('role', 'alert');
  warning.id = 'devagents-version-error';
  warning.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:#151515;color:#fff;padding:40px;font:20px system-ui;white-space:pre-wrap;overflow:auto';
  warning.textContent = `DevAgents: version incompatible\n\n${message}`;
  target.replaceChildren(warning);
  console.error('[version-check]', message);
}

/** Fail closed before panels dispatch operations; also catches an old host. */
export async function checkVersion(core: Pick<CoreApi, 'version'>, report = showVersionError): Promise<boolean> {
  try {
    const versions = await core.version(buildIdentity);
    if (typeof versions.host !== 'string' || typeof versions.engine !== 'string') {
      throw new Error('El host no declara el protocolo de version esperado');
    }
    const mismatch = versionMismatch('WebUI', versions.host, buildIdentity) ||
      versionMismatch('motor DLL', versions.host, versions.engine);
    if (mismatch) throw new Error(mismatch);
    return true;
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    const instruction = detail.includes('Actualiza')
      ? '' : ' Actualiza el host, motor y WebUI desde el mismo paquete.';
    report(`WebUI ${buildIdentity}: ${detail.replace(/\.+$/, '')}.${instruction}`);
    return false;
  }
}
