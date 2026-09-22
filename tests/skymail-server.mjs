import { randomUUID } from "node:crypto";
import { createServer as createHttpServer } from "node:http";
import { createServer as createTcpServer } from "node:net";

// Integration fixture for K5. Two protocols, one process:
//
//   HTTP  :8080  the SkyMail single-mail task API the sky-mail sender posts to.
//   SMTP  :1025  the sink Keycloak's own sender delivers to when SkyMail fails,
//                so the fallback can be proved to still put the mail out.
//
// Every accepted mail is printed as one JSON line so the harness can read it from
// `docker compose logs`, and nothing needs a published port.

const mailTaskPath = "/v1/mail_tasks/single";
const maximumBodyBytes = 16 * 1024;
const requiredRoles = ["skymail:access", "skymail:mails:send"];
const requiredVariables = [
  "link",
  "linkExpirationMinutes",
  "firstName",
  "username",
  "realmDisplayName",
  "subjectKey",
];
// Mails to these recipients are refused so the harness can prove both fallback paths:
// an unavailable SkyMail, and a template key SkyMail does not know (or that was archived).
const unavailableRecipientPrefix = process.env.SKYMAIL_UNAVAILABLE_RECIPIENT ?? "skymail-fallback@";
const missingTemplateRecipientPrefix =
  process.env.SKYMAIL_MISSING_TEMPLATE_RECIPIENT ?? "skymail-missing@";
const httpPort = parsePositiveInteger(process.env.SKYMAIL_HTTP_PORT ?? "8080");
const smtpPort = parsePositiveInteger(process.env.SKYMAIL_SMTP_PORT ?? "1025");

function parsePositiveInteger(value) {
  if (!/^[1-9][0-9]*$/.test(value)) {
    throw new Error("Expected a positive integer.");
  }
  return Number.parseInt(value, 10);
}

function emit(record) {
  process.stdout.write(`SKYMAIL_FIXTURE ${JSON.stringify(record)}\n`);
}

function reject(response, status, reason) {
  emit({ event: "rejected", status, reason });
  const body = JSON.stringify({ detail: reason });
  response.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
  response.end(body);
}

/** The service-account claims, without verifying the signature: this is a fixture. */
function serviceAccountClaims(authorization) {
  if (typeof authorization !== "string" || !authorization.startsWith("Bearer ")) {
    return null;
  }
  const parts = authorization.slice("Bearer ".length).split(".");
  if (parts.length !== 3) {
    return null;
  }
  try {
    return JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
  } catch {
    return null;
  }
}

const httpServer = createHttpServer((request, response) => {
  if (request.method !== "POST" || request.url !== mailTaskPath) {
    reject(response, 404, "unknown endpoint");
    return;
  }
  if (!String(request.headers["content-type"] ?? "").startsWith("application/json")) {
    reject(response, 415, "unsupported media type");
    return;
  }

  const claims = serviceAccountClaims(request.headers.authorization);
  if (claims === null) {
    reject(response, 401, "missing or unreadable bearer token");
    return;
  }
  const roles = claims.resource_access?.skymail?.roles ?? [];
  const missingRoles = requiredRoles.filter((role) => !roles.includes(role));
  if (missingRoles.length > 0) {
    reject(response, 403, `service account lacks ${missingRoles.join(" ")}`);
    return;
  }

  const chunks = [];
  let bodyBytes = 0;
  request.on("data", (chunk) => {
    bodyBytes += chunk.byteLength;
    if (bodyBytes > maximumBodyBytes) {
      request.destroy();
      return;
    }
    chunks.push(chunk);
  });
  request.on("end", () => {
    if (bodyBytes > maximumBodyBytes) {
      return;
    }
    let body;
    try {
      body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch {
      reject(response, 400, "body is not JSON");
      return;
    }
    if (typeof body.template_key !== "string" || body.template_key === "") {
      reject(response, 400, "neither template_key nor template_id was given");
      return;
    }
    const variables = body.body_variables ?? {};
    const missingVariables = requiredVariables.filter(
      (name) => typeof variables[name] !== "string",
    );

    emit({
      event: "mail_task",
      template_key: body.template_key,
      recipient_email: body.recipient_email,
      recipient_full_name: body.recipient_full_name,
      body_variables: variables,
      missing_variables: missingVariables,
      azp: claims.azp ?? claims.clientId ?? null,
      roles,
    });

    if (missingVariables.length > 0) {
      reject(response, 400, `missing variables ${missingVariables.join(" ")}`);
      return;
    }
    const recipient = String(body.recipient_email ?? "");
    if (recipient.startsWith(missingTemplateRecipientPrefix)) {
      reject(response, 404, "template key not found");
      return;
    }
    if (recipient.startsWith(unavailableRecipientPrefix)) {
      reject(response, 500, "fixture refuses this recipient so the fallback can be proved");
      return;
    }

    const id = randomUUID();
    emit({ event: "accepted", template_key: body.template_key, id });
    response.writeHead(201, { "content-type": "application/json", "cache-control": "no-store" });
    response.end(JSON.stringify({ id }));
  });
});

// --- SMTP sink for the fallback ----------------------------------------------------------

const smtpServer = createTcpServer((socket) => {
  let pending = "";
  let recipients = [];
  let inData = false;
  let message = "";

  const say = (line) => socket.write(`${line}\r\n`);

  say("220 skymail-fixture ESMTP");
  socket.setEncoding("utf8");
  socket.on("data", (chunk) => {
    pending += chunk;
    let newline = pending.indexOf("\r\n");
    while (newline >= 0) {
      const line = pending.slice(0, newline);
      pending = pending.slice(newline + 2);
      newline = pending.indexOf("\r\n");

      if (inData) {
        if (line === ".") {
          inData = false;
          emit({ event: "smtp_message", recipients, bytes: message.length });
          recipients = [];
          message = "";
          say("250 2.0.0 Queued");
        } else {
          message += `${line.startsWith("..") ? line.slice(1) : line}\n`;
        }
        continue;
      }

      const command = line.slice(0, 4).toUpperCase();
      if (command === "EHLO" || command === "HELO") {
        say("250 skymail-fixture");
      } else if (command === "MAIL") {
        say("250 2.1.0 Sender ok");
      } else if (command === "RCPT") {
        recipients.push(line.replace(/^RCPT TO:\s*/i, "").replace(/[<>]/g, "").trim());
        say("250 2.1.5 Recipient ok");
      } else if (command === "DATA") {
        inData = true;
        say("354 End data with <CR><LF>.<CR><LF>");
      } else if (command === "RSET") {
        recipients = [];
        message = "";
        say("250 2.0.0 Reset");
      } else if (command === "NOOP") {
        say("250 2.0.0 Ok");
      } else if (command === "QUIT") {
        say("221 2.0.0 Bye");
        socket.end();
      } else {
        say("502 5.5.2 Command not implemented");
      }
    }
  });
  socket.on("error", () => socket.destroy());
});

httpServer.listen(httpPort, "0.0.0.0", () => {
  smtpServer.listen(smtpPort, "0.0.0.0", () => {
    process.stdout.write("SkyMail fixture is ready.\n");
  });
});
