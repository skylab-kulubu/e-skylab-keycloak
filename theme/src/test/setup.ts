import "@testing-library/jest-dom/vitest";

// jsdom has no 2D canvas; the background grid draws nothing without one.
// Node-environment suites (i18n.test.ts) have no HTMLCanvasElement at all.
if (typeof HTMLCanvasElement !== "undefined") {
  HTMLCanvasElement.prototype.getContext = () => null;
}
