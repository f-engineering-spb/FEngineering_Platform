/**
 * DVG Component Scaffold for Launcher v3
 * Модуль будущего просмотрщика чертежей ДВГ.
 * Изолирован от основного кода Launcher (app.js), не влияет на текущие окна.
 */
class DvgPreviewModule {
  constructor(options = {}) {
    this.container = options.container || null;
    this.activeDwgPath = null;
    this.version = "0.1.0-scaffold";
  }

  init() {
    console.info("[Launcher DVG] Scaffold initialized");
  }

  setFile(path) {
    this.activeDwgPath = path;
  }
}

if (typeof window !== "undefined") {
  window.DvgPreviewModule = DvgPreviewModule;
}
