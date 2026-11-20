import { ThemeTokens, ThemeManager } from './theme_registry';

/**
 * Tema aportado desde fuera del registro base: demuestra que añadir un tema no
 * requiere tocar ni un componente, solo rellenar el mismo contrato de tokens.
 */
export const matrixGreenTheme: ThemeTokens = {
  id: 'matrix-green',
  name: 'Matrix Digital Rain',
  base: 'dark',
  colors: {
    bgApp: '#010801',
    bgTitlebar: '#010801',
    bgActivityBar: '#010801',
    bgSidebar: '#041104',
    bgMain: '#010801',
    bgPanel: '#000400',
    bgStatusBar: '#010801',
    surface1: '#051b05',
    surface2: '#082708',
    surface3: '#0c360c',
    border: 'rgba(0,255,65,0.16)',
    borderStrong: 'rgba(0,255,65,0.34)',
    accent: '#00ff41',
    accentHover: '#5bff85',
    accentSoft: 'rgba(0,255,65,0.13)',
    accentContrast: '#010801',
    fg: '#c8ffd4',
    fgMuted: '#4fd96a',
    fgSubtle: '#2a8f3d',
    success: '#00ff41',
    warning: '#d8ff3a',
    danger: '#ff4141',
    info: '#41ffd8',
  },
};

export function registerMatrixGreenTheme(manager: ThemeManager): void {
  manager.registerTheme(matrixGreenTheme);
}
