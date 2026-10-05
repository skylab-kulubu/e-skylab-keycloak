// Builds the e-skylab-welcome Keycloak theme, the page Keycloak serves at `/` (WelcomeResource),
// into dist_welcome/e-skylab-welcome/welcome/:
//   theme.properties         redirectToAdmin=false: no redirect to the Admin Console
//   index.ftl                rendered once from src/welcome/template.tsx (static, no script)
//   resources/welcome.css    src/welcome/welcome.css with the skylcn-ui tokens, Space Grotesk and
//                            the login stylesheet it imports, bundled by Vite
//   resources/*.woff2        the bundled Space Grotesk files the stylesheet points at
//   resources/skylab-logo.png the favicon
// The Dockerfile copies e-skylab-welcome/ to /opt/keycloak/themes/ and selects it with
// KC_SPI_THEME__WELCOME_THEME. tests/check-welcome-theme.sh checks the output.
import { copyFile, mkdir, readdir, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import react from "@vitejs/plugin-react";
import { build, createServer } from "vite";

const themeRoot = fileURLToPath(new URL("../", import.meta.url));
const outputRoot = new URL("../dist_welcome/", import.meta.url);
const welcomeDirectory = new URL("e-skylab-welcome/welcome/", outputRoot);
const resourcesDirectory = new URL("resources/", welcomeDirectory);

await rm(outputRoot, { recursive: true, force: true });

// 1. The stylesheet and the fonts it points at, with stable names and relative URLs.
await build({
  configFile: false,
  root: themeRoot,
  base: "./",
  logLevel: "warn",
  publicDir: false,
  build: {
    outDir: fileURLToPath(resourcesDirectory),
    emptyOutDir: true,
    assetsInlineLimit: 0,
    copyPublicDir: false,
    rollupOptions: {
      input: { welcome: fileURLToPath(new URL("../src/welcome/welcome.css", import.meta.url)) },
      output: { assetFileNames: "[name][extname]" }
    }
  }
});

// A stylesheet entry leaves an empty script chunk behind; the page loads no script.
for (const name of await readdir(resourcesDirectory)) {
  if (name.endsWith(".js")) {
    await rm(new URL(name, resourcesDirectory));
  }
}

// 2. index.ftl, rendered from the same React components as the login theme.
const server = await createServer({
  configFile: false,
  root: themeRoot,
  logLevel: "warn",
  appType: "custom",
  plugins: [react()],
  // One module rendered on the server: no browser dependency scan of index.html.
  optimizeDeps: { noDiscovery: true, entries: [] },
  server: { middlewareMode: true, hmr: false, ws: false }
});
try {
  const { renderWelcomeTemplate } = await server.ssrLoadModule("/src/welcome/template.tsx");
  await writeFile(new URL("index.ftl", welcomeDirectory), renderWelcomeTemplate(), "utf8");
} finally {
  await server.close();
}

// 3. The favicon and the theme's properties.
await mkdir(resourcesDirectory, { recursive: true });
await copyFile(new URL("../src/assets/skylab-logo.png", import.meta.url), new URL("skylab-logo.png", resourcesDirectory));
await writeFile(
  new URL("theme.properties", welcomeDirectory),
  [
    "# e-SKY LAB landing page at / (Keycloak's welcome page). Built by theme/scripts/build-welcome-theme.mjs.",
    "# Never redirect / to the Admin Console; the page links only to the club's own apps.",
    "redirectToAdmin=false",
    ""
  ].join("\n"),
  "utf8"
);

console.log(`welcome theme written to ${fileURLToPath(new URL("e-skylab-welcome/", outputRoot))}`);
