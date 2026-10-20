import "@testing-library/jest-dom/vitest";
import { afterEach } from "vitest";
import { resetNavigationLoading } from "../login/navigationLoading";

// jsdom has no 2D canvas; the background grid draws nothing without one.
// Node-environment suites (i18n.test.ts) have no HTMLCanvasElement at all.
if (typeof HTMLCanvasElement !== "undefined") {
  HTMLCanvasElement.prototype.getContext = () => null;
}

// A step started in one test (chooseExecution) must not leave the next one pending.
afterEach(() => {
  if (typeof document !== "undefined") resetNavigationLoading();
});
