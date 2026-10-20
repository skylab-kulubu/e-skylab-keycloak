import react from "@vitejs/plugin-react";
import { keycloakify } from "keycloakify/vite-plugin";
import { defineConfig, type Plugin } from "vite";

/**
 * The entry script blocks the first render until it has run (`blocking="render"`), so a page
 * reached through a cross-document View Transition shows its card in the very first frame
 * instead of an empty background (src/login/pageTransitions.ts). Vite rewrites the entry tag on
 * build, so the attribute is added after it.
 */
function renderBlockingEntry(): Plugin {
  return {
    name: "sl-render-blocking-entry",
    transformIndexHtml: {
      order: "post",
      handler: html => html.replace(/<script type="module"(?![^>]*\bblocking=)/g, '<script type="module" blocking="render"')
    }
  };
}

export default defineConfig({
  plugins: [
    react(),
    renderBlockingEntry(),
    keycloakify({
      accountThemeImplementation: "none",
      themeName: "e-skylab-theme",
      keycloakVersionTargets: {
        "22-to-25": false,
        "all-other-versions": "e-skylab-theme-2.0.1.jar"
      }
    })
  ]
});
