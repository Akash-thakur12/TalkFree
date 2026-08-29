"use strict";

/**
 * Standalone Twilio Voice webhook — POST /call returns TwiML to dial `To`.
 * Use as a dedicated service, or merge routes into your main Express app.
 *
 * Run: PORT=3000 node index.voip-webhook.standalone.js
 * Env: TWILIO_CALLER_ID (E.164 caller ID for <Dial callerId>)
 */

const express = require("express");
const twilio = require("twilio");

const PORT = Number(process.env.PORT || 3000);
const TWILIO_CALLER_ID = String(process.env.TWILIO_CALLER_ID || "").trim();

const app = express();

app.use(express.json());
app.use(express.urlencoded({ extended: false }));

/** Normalize to E.164: + then digits only. Returns null if unusable. */
function toE164(raw) {
  const s = String(raw ?? "").trim();
  if (!s) return null;
  if (s.startsWith("+")) {
    const digits = s.slice(1).replace(/\D/g, "");
    return digits.length >= 8 ? `+${digits}` : null;
  }
  const digits = s.replace(/\D/g, "");
  if (digits.length < 8) return null;
  return `+${digits}`;
}

app.get("/health", (_req, res) => {
  res.type("text/plain").send("OK");
});

app.post("/call", (req, res) => {
  console.log("[POST /call] incoming body:", JSON.stringify(req.body));

  const rawTo = req.body?.To ?? req.body?.to;
  const e164 = rawTo != null ? toE164(rawTo) : null;

  const vr = new twilio.twiml.VoiceResponse();

  if (!e164) {
    console.warn("[POST /call] missing or invalid To; Say Invalid number");
    vr.say({ voice: "alice" }, "Invalid number");
    res.type("text/xml");
    return res.status(200).send(vr.toString());
  }

  console.log("[POST /call] dialed number (E.164):", e164);

  const dialOpts = {};
  if (TWILIO_CALLER_ID) {
    dialOpts.callerId = TWILIO_CALLER_ID;
  }
  const dial = vr.dial(dialOpts);
  dial.number(e164);

  res.type("text/xml");
  return res.status(200).send(vr.toString());
});

app.use((req, res) => {
  res.status(404).type("text/plain").send("Not found");
});

app.listen(PORT, () => {
  console.log(`VoIP webhook server listening on port ${PORT}`);
});
