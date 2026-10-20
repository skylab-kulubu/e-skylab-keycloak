import { StrictMode } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import KcLoginPage from "./login/KcPage";
import { continueNavigationLoading, installNavigationLoading } from "./login/navigationLoading";
import { installPageTransitions } from "./login/pageTransitions";
import { installPasskeyButtonReady } from "./login/passkeyButtonReady";

const root = document.getElementById("root");

if (root === null) {
  throw new Error("Missing theme root");
}

if (window.kcContext === undefined && import.meta.env.DEV) {
  const { getDevKcContext } = await import("./devKcContext");
  window.kcContext = getDevKcContext();
}

installPageTransitions();
installNavigationLoading();
installPasskeyButtonReady();

// The login pages are imported here, not lazily through kc.gen.tsx, and the first render is
// synchronous: with the render-blocking entry script (vite.config.ts) the page's first frame
// already holds the card, which is what a cross-document View Transition captures.
flushSync(() => {
  createRoot(root).render(
    <StrictMode>
      {window.kcContext === undefined ? (
        <main className="sl-fallback" aria-labelledby="sl-fallback-title">
          <h1 id="sl-fallback-title">SKY LAB Hesap</h1>
          <p>Kimlik doğrulama ekranı yalnızca SKY LAB giriş hizmeti üzerinden açılır.</p>
        </main>
      ) : (
        <KcLoginPage kcContext={window.kcContext} />
      )}
    </StrictMode>
  );
});

// Still before the first frame: a step that answered in less than its minimum keeps loading here.
continueNavigationLoading();
