import { useEffect, useRef } from "react";
import { kcSanitize } from "keycloakify/lib/kcSanitize";

export type PageMessageProps = {
  message: { type: "success" | "warning" | "error" | "info"; summary: string };
};

/**
 * Keycloak's page-wide message (not tied to one field): the reset e-mail
 * confirmation, a failed YTÜ Microsoft sign-in, an expired action. Every page
 * renders it as the first thing under the card heading, never inside a section
 * the person has to open first. Errors are alerts, everything else a status.
 *
 * On load the message takes focus, so a screen reader reads it first and the
 * next Tab continues from it, unless the page already focused a field itself
 * (an `autoFocus` input wins: typing there is what the person came to do).
 */
export default function PageMessage(props: PageMessageProps) {
  const { message } = props;
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const active = document.activeElement;
    if (active === null || active === document.body || active === document.documentElement) {
      ref.current?.focus();
    }
  }, []);

  const isError = message.type === "error";

  return (
    <div
      ref={ref}
      id="sl-page-message"
      className={`sl-legacy-alert sl-legacy-alert--${message.type}`}
      role={isError ? "alert" : "status"}
      aria-live={isError ? "assertive" : "polite"}
      tabIndex={-1}
      dangerouslySetInnerHTML={{ __html: kcSanitize(message.summary) }}
    />
  );
}
