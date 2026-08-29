"use strict";

const fs = require("fs");
const path = require("path");

const envPath = path.join(__dirname, ".env");
require("dotenv").config({ path: envPath });

const crypto = require("crypto");
const express = require("express");
const cors = require("cors");
const cron = require("node-cron");
const twilio = require("twilio");
const Razorpay = require("razorpay");

const {
  TWILIO_ACCOUNT_SID,
  TWILIO_AUTH_TOKEN,
  TWILIO_API_KEY_SID,
  TWILIO_API_KEY_SECRET,
  TWILIO_TWIML_APP_SID,
  TWILIO_APP_SID,
  TWILIO_CALLER_ID,
  PORT = 3000,
  PUBLIC_BASE_URL = "https://talkfree-server.onrender.com",
} = process.env;

const OUTGOING_APP_SID = String(
  TWILIO_TWIML_APP_SID || TWILIO_APP_SID || "",
).trim();

const app = express();
app.use((req, res, next) => {
  console.log("Incoming:", req.method, req.url);
  next();
});
app.use(cors());
app.use(express.json());
app.use(express.urlencoded({ extended: false }));

app.get("/", (req, res) => {
  res.send("Server is alive");
});

function requireEnv(name, val) {
  if (!val || String(val).trim() === "") {
    throw new Error(`Missing env: ${name}`);
  }
}

try {
  requireEnv("TWILIO_ACCOUNT_SID", TWILIO_ACCOUNT_SID);
  requireEnv("TWILIO_AUTH_TOKEN", TWILIO_AUTH_TOKEN);
  requireEnv("TWILIO_CALLER_ID", TWILIO_CALLER_ID);
  requireEnv("TWILIO_API_KEY_SID", TWILIO_API_KEY_SID);
  requireEnv("TWILIO_API_KEY_SECRET", TWILIO_API_KEY_SECRET);
  requireEnv("TWILIO_TWIML_APP_SID or TWILIO_APP_SID", OUTGOING_APP_SID);
} catch (e) {
  console.error(e.message);
  const examplePath = path.join(__dirname, ".env.example");
  if (!fs.existsSync(envPath)) {
    console.error(`\nNo file at: ${envPath}`);
    console.error(`Copy .env.example to .env in this folder, then fill in your Twilio values.`);
  } else {
    console.error(`\nEdit ${envPath} — one or more required variables are empty.`);
  }
  if (fs.existsSync(examplePath)) {
    console.error(`Template: ${examplePath}`);
  }
  process.exit(1);
}

const twilioClient = twilio(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN);

/** Optional — enables POST /grant-reward (secured credits). Set FIREBASE_SERVICE_ACCOUNT_JSON in .env */
let firebaseAdmin = null;
try {
  const faJson = process.env.FIREBASE_SERVICE_ACCOUNT_JSON;
  if (faJson) {
    const admin = require("firebase-admin");
    if (!admin.apps.length) {
      admin.initializeApp({
        credential: admin.credential.cert(JSON.parse(faJson)),
      });
    }
    firebaseAdmin = admin;
    console.log("Firebase Admin: /grant-reward, /assign-number, /send-sms, /admin/upgrade-user enabled");
  } else {
    console.warn("FIREBASE_SERVICE_ACCOUNT_JSON unset — /grant-reward, /assign-number, /send-sms, /admin/upgrade-user return 503");
  }
} catch (e) {
  console.warn("Firebase Admin init failed — /grant-reward disabled:", e.message);
}

/**
 * @returns {Promise<string|null>} Firebase Auth uid, or `null` if a 4xx/5xx was already sent.
 */
async function getUidFromBearer(req, res) {
  if (!firebaseAdmin) {
    res.status(503).json({ error: "Firebase Admin not configured" });
    return null;
  }
  const auth = req.headers.authorization || "";
  const m = /^Bearer\s+(.+)$/i.exec(auth);
  if (!m) {
    res.status(401).json({ error: "Missing Authorization: Bearer <Firebase ID token>" });
    return null;
  }
  try {
    return (await firebaseAdmin.auth().verifyIdToken(m[1])).uid;
  } catch (e) {
    console.error("verifyIdToken (getUidFromBearer):", e.message);
    res.status(401).json({ error: "Invalid or expired token" });
    return null;
  }
}

/** Twilio webhooks use `${publicBase}/…` — must NOT end with `/` or you get `…//sms-webhook`. */
function normalizePublicBase(raw) {
  return String(raw ?? "").trim().replace(/\/+$/, "");
}

const publicBase = normalizePublicBase(PUBLIC_BASE_URL);
if (publicBase && !/^https:\/\//i.test(publicBase)) {
  console.warn("PUBLIC_BASE_URL should normally start with https:// for Twilio webhooks.");
}

/** Re-read at request time so Render env sync issues surface in logs (not only at boot). */
function getTwilioCallerIdOrThrow(stepLabel) {
  const raw = process.env.TWILIO_CALLER_ID;
  const v = raw != null ? String(raw).trim() : "";
  if (!v) {
    const msg = `${stepLabel}: TWILIO_CALLER_ID is missing or empty in process.env — set it in Render → Environment (E.164, e.g. +15551234567) and redeploy.`;
    console.error("[send-sms]", msg, {
      envKeyDefined: raw !== undefined,
      rawLength: raw == null ? null : String(raw).length,
    });
    const err = new Error(msg);
    err.http = 500;
    err.code = "MISSING_TWILIO_CALLER_ID";
    throw err;
  }
  return v;
}

/**
 * Normalize phone strings toward E.164: strip non-digits, prepend +.
 * US 10-digit national → +1…
 */
function toE164(input) {
  const s = String(input ?? "").trim();
  if (!s) return "";
  const digits = s.replace(/\D/g, "");
  if (digits.length < 10) return "";
  if (digits.length === 10) return `+1${digits}`;
  return `+${digits}`;
}

function readAssignedNumberFromUserDoc(d) {
  if (!d || typeof d !== "object") return "";
  const keys = ["assigned_number", "phoneNumber", "virtual_number", "allocatedNumber", "number"];
  for (const k of keys) {
    const v = d[k];
    if (v == null) continue;
    const t = String(v).trim();
    if (t !== "" && t.toLowerCase() !== "none") return t;
  }
  return "";
}

/**
 * Prefer Firestore `assigned_number` (user's Twilio line); else `TWILIO_CALLER_ID`.
 */
function resolveOutgoingSmsFrom(userDoc, fallbackCallerRaw) {
  const assignedRaw = readAssignedNumberFromUserDoc(userDoc);
  const assignedE164 = toE164(assignedRaw);
  if (assignedE164 && /^\+[1-9]\d{8,14}$/.test(assignedE164)) {
    return { from: assignedE164, source: "firestore:assigned_number" };
  }
  const fb = String(fallbackCallerRaw ?? "").trim();
  const fbE164 = toE164(fb) || (fb.startsWith("+") ? fb : toE164("+" + fb.replace(/\D/g, "")));
  return { from: fbE164 || fb, source: "env:TWILIO_CALLER_ID" };
}

/**
 * TwiML for PSTN outbound: dial `to` with caller ID. Used by:
 * - Twilio Voice SDK (TwiML App Voice URL should be POST {PUBLIC_BASE_URL}/call)
 * - REST twilioClient.calls.create `url` → use /twiml/voice so the callee leg gets real Dial, not /voice Say test.
 */
function voiceResponseDialPstn(toRaw) {
  const vr = new twilio.twiml.VoiceResponse();
  const to = toRaw != null ? String(toRaw).trim() : "";
  if (!to) {
    vr.say({ voice: "alice" }, "No destination number.");
  } else {
    const dial = vr.dial({ callerId: TWILIO_CALLER_ID });
    dial.number(to);
  }
  return vr;
}

/** Optional test: GET /voice — Say only (do not use as calls.create `url` for real PSTN). */
app.all("/voice", (req, res) => {
  console.log("Twilio hit /voice (test Say)");
  res.type("text/xml");
  res.send(
    new twilio.twiml.VoiceResponse()
      .say({ voice: "alice" }, "TalkFree server voice test — use /twiml/voice or POST /call for Dial.")
      .toString(),
  );
});

/**
 * TwiML Dial — for REST `calls.create({ url })` callbacks. Twilio sends To in query or body.
 * GET /twiml/voice?To=+1... or POST with form field To.
 */
app.all("/twiml/voice", (req, res) => {
  const to =
    (req.body && (req.body.To || req.body.to)) ||
    (req.query && (req.query.To || req.query.to)) ||
    "";
  res.type("text/xml");
  res.send(voiceResponseDialPstn(to).toString());
});

const twimlDialUrl = `${publicBase}/twiml/voice`;

const AccessToken = twilio.jwt.AccessToken;
const VoiceGrant = AccessToken.VoiceGrant;

/**
 * GET /call — **disabled.** Legacy server-initiated PSTN had no credit validation.
 * Outbound calls use Twilio Voice SDK → `POST /call` (form) + `/call-live-tick` billing.
 */
app.get("/call", (_req, res) => {
  return res.status(410).json({
    error: "disabled",
    message: "GET /call is disabled. Use the in-app Twilio Voice client (token + form POST /call TwiML).",
  });
});

/**
 * GET /token — Twilio Voice SDK access JWT.
 * **Auth:** `Authorization: Bearer <Firebase ID token>`. Identity is always the token uid (client cannot spoof).
 */
app.get("/token", async (req, res) => {
  const uid = await getUidFromBearer(req, res);
  if (!uid) return;
  const identity = String(uid).slice(0, 128);
  const token = new AccessToken(
    TWILIO_ACCOUNT_SID,
    TWILIO_API_KEY_SID,
    TWILIO_API_KEY_SECRET,
    { identity },
  );
  const grant = new VoiceGrant({
    outgoingApplicationSid: OUTGOING_APP_SID,
    incomingAllow: true,
  });
  token.addGrant(grant);
  res.json({ identity, token: token.toJwt() });
});

app.post("/call", async (req, res) => {
  // JSON branch was server-initiated PSTN without Firestore credit checks — disabled (Flutter unused).
  if (req.is("application/json")) {
    return res.status(410).json({
      error: "disabled",
      message:
        "JSON POST /call is disabled. Use Twilio Voice SDK outbound (form POST /call returns TwiML) and server billing ticks.",
    });
  }

  // Twilio Voice SDK / TwiML App webhook (application/x-www-form-urlencoded): return TwiML to <Dial> PSTN.
  const to = req.body.To || req.body.to;
  res.type("text/xml");
  res.send(voiceResponseDialPstn(to).toString());
});

/** Free tier call credits per rewarded ad (env: `REWARD_GRANT_CREDITS_FREE`, default 2). */
const REWARD_GRANT_CREDITS_FREE = Number(process.env.REWARD_GRANT_CREDITS_FREE ?? 2);
/** First lifetime rewarded ad (call) — extra dopamine for onboarding (env: `FIRST_AD_GRANT_CREDITS_FREE`, default 3). */
const FIRST_AD_GRANT_CREDITS_FREE = Number(process.env.FIRST_AD_GRANT_CREDITS_FREE ?? 3);
/** Premium tier credits per ad after first lifetime. */
const REWARD_GRANT_CREDITS_PREMIUM = Number(process.env.REWARD_GRANT_CREDITS_PREMIUM || 3);
const MAX_ADS_PER_DAY_FREE = Number(process.env.MAX_ADS_PER_DAY_FREE || 25);
const MAX_ADS_PER_DAY_PREMIUM = Number(process.env.MAX_ADS_PER_DAY_PREMIUM || 25);
const AD_GAP_SECONDS_FREE = Number(process.env.AD_GAP_SECONDS_FREE || 45);
const AD_GAP_SECONDS_PREMIUM = Number(process.env.AD_GAP_SECONDS_PREMIUM || 10);
/** Optional INR micro-cost per rewarded-ad grant (infra); extend with call/SMS cost in other handlers. */
const EST_COST_INR_PER_REWARDED_AD = Number(process.env.EST_COST_INR_PER_REWARDED_AD ?? 0);
/** Rough rewarded-ad revenue per completion (INR); tune 0.3–0.5 for eCPM modeling. Profit ≈ this − `total_cost_estimated`. */
const EST_REVENUE_INR_PER_REWARDED_AD = Number(process.env.EST_REVENUE_INR_PER_REWARDED_AD ?? 0.4);
/** Rough Twilio PSTN cost model for analytics (INR per billed talk minute). */
const EST_COST_INR_PER_CALL_MINUTE = Number(process.env.EST_COST_INR_PER_CALL_MINUTE ?? 2);
/** Rough carrier cost per outbound SMS (INR) for `user_stats.total_cost_estimated`. */
const EST_COST_INR_PER_OUTBOUND_SMS = Number(process.env.EST_COST_INR_PER_OUTBOUND_SMS ?? 2.5);
/** One-time estimated lease/provisioning cost when a US line is assigned (INR). */
const EST_NUMBER_PROVISION_COST_INR = Number(process.env.EST_NUMBER_PROVISION_COST_INR ?? 25);
/** Same idempotency key dedupes within this window; older key rows may be overwritten (still capped by reward_keys ring). */
const REWARD_IDEMPOTENCY_TTL_MS = Number(process.env.REWARD_IDEMPOTENCY_TTL_MS || 2 * 60 * 1000);
/** `client` (default): require JSON `adVerified: true` after SDK reward. `ssv`: reserved until SSV webhook issues grants. */
const AD_VERIFICATION_MODE = String(process.env.AD_VERIFICATION_MODE || "client")
  .trim()
  .toLowerCase();

/** In-process counters for log/metrics scraping (Grafana/BigQuery friendly). */
const grantRewardOutcomeMetrics = {
  granted_count: 0,
  deduped_count: 0,
  blocked_cooldown_count: 0,
  blocked_daily_cap_count: 0,
};

function bumpGrantRewardMetric(name) {
  if (Object.prototype.hasOwnProperty.call(grantRewardOutcomeMetrics, name)) {
    grantRewardOutcomeMetrics[name] += 1;
  }
}

function grantRewardMetricSnapshot() {
  return { ...grantRewardOutcomeMetrics };
}

function utcDayKey(d = new Date()) {
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-${String(d.getUTCDate()).padStart(2, "0")}`;
}

/** Add calendar days to a `utcDayKey` string (YYYY-MM-DD). */
function utcDayKeyAddDays(dayKey, deltaDays) {
  const parts = String(dayKey).split("-");
  if (parts.length !== 3) return dayKey;
  const y = Number(parts[0]);
  const mo = Number(parts[1]) - 1;
  const da = Number(parts[2]);
  const dt = new Date(Date.UTC(y, mo, da + deltaDays));
  return utcDayKey(dt);
}

/** Bonus reward credits when [ad_streak_count] hits these days (first ad of that UTC day). */
const AD_STREAK_MILESTONE_BONUS = {
  3: 5,
  7: 10,
  14: 25,
  30: 50,
};

function readAdsWatchedToday(d, dayKey) {
  const reset = d.last_reset_date || d.adRewardsDayKey || "";
  if (reset !== dayKey) return 0;
  if (d.ads_watched_today !== undefined && d.ads_watched_today !== null) {
    return Number(d.ads_watched_today);
  }
  if (d.adsWatchedToday !== undefined && d.adsWatchedToday !== null) {
    return Number(d.adsWatchedToday);
  }
  return Number(d.adRewardsCount || 0);
}

/** Daily ad count for caps / dynamic gap — server fields only (`ads_watched_today` + `adRewardsCount` legacy). */
function readAdsWatchedTodayAuthoritative(d, dayKey) {
  const reset = d.last_reset_date || d.adRewardsDayKey || "";
  if (reset !== dayKey) return 0;
  if (d.ads_watched_today !== undefined && d.ads_watched_today !== null) {
    const n = Number(d.ads_watched_today);
    if (Number.isFinite(n)) return Math.max(0, Math.floor(n));
  }
  const legacy = Number(d.adRewardsCount ?? 0);
  return Number.isFinite(legacy) ? Math.max(0, Math.floor(legacy)) : 0;
}

function rewardKeyAtMillis(keyData) {
  if (!keyData || typeof keyData !== "object") return 0;
  const at = keyData.at;
  if (at && typeof at.toMillis === "function") return at.toMillis();
  const n = Number(at);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

function readAdProgress(d) {
  if (d.ad_progress !== undefined && d.ad_progress !== null) {
    return Number(d.ad_progress);
  }
  return Number(d.adRewardCycleCount || 0);
}

/** Prefer `ad_sub_counter`; else legacy `ad_progress` mod 4 (values 0–3). */
function readAdSubCounter(d) {
  let n;
  if (d.ad_sub_counter !== undefined && d.ad_sub_counter !== null) {
    n = Number(d.ad_sub_counter);
  } else {
    n = readAdProgress(d);
  }
  if (!Number.isFinite(n)) return 0;
  return ((n % 4) + 4) % 4;
}

/** `/grant-reward` cooldown: only numeric `last_ad_grant_server_ms` (UI timestamp fields are not used for gap math). */
function readLastAdGrantServerMs(d) {
  if (!d || typeof d !== "object") return 0;
  const n = Number(d.last_ad_grant_server_ms);
  if (Number.isFinite(n) && n > 0) return Math.floor(n);
  return 0;
}

function readGrantAttemptsToday(d, dayKey) {
  const reset = String(d.grant_attempts_day_key || "");
  if (reset !== String(dayKey || "")) return 0;
  const n = d.grant_attempts_today;
  if (n === undefined || n === null || n === "") return 0;
  const x = Number(n);
  return Number.isFinite(x) ? Math.max(0, Math.floor(x)) : 0;
}

/** Best-effort: count rate-limited grant tries (daily cap / cooldown) for abuse analytics. */
async function incrementGrantAttemptsTodayForUid(uid) {
  if (!firebaseAdmin || !uid) return;
  const { Timestamp } = firebaseAdmin.firestore;
  const db = firebaseAdmin.firestore();
  const ref = db.collection("users").doc(uid);
  try {
    await db.runTransaction(async (t) => {
      const doc = await t.get(ref);
      if (!doc.exists) return;
      const d = doc.data();
      const nowMs = Timestamp.now().toMillis();
      const dayKey = utcDayKey(new Date(nowMs));
      let ga = readGrantAttemptsToday(d, dayKey);
      if (String(d.grant_attempts_day_key || "") !== dayKey) ga = 0;
      ga += 1;
      t.update(ref, {
        grant_attempts_today: ga,
        grant_attempts_day_key: dayKey,
      });
    });
  } catch (_) {
    /* ignore */
  }
}

function readFirestoreDate(d, keys) {
  for (const k of keys) {
    const v = d[k];
    if (v && typeof v.toDate === "function") return v.toDate();
  }
  return null;
}

/** POST /grant-reward body: `purpose` must be `call` | `number` | `otp` (one reward per ad). */
function normalizeGrantPurpose(raw) {
  const s = String(raw ?? "")
    .trim()
    .toLowerCase();
  if (s === "call" || s === "number" || s === "otp") return s;
  return "";
}

/** Wrong HTTP method → not a silent 404 (helps debug mobile / proxies). */
app.get("/grant-reward", (_req, res) => {
  res.set("Allow", "POST");
  return res.status(405).json({
    error: "Method not allowed",
    message:
      "Use POST /grant-reward with JSON { purpose, idempotencyKey, adVerified: true } and Authorization: Bearer <Firebase ID token>",
  });
});

/**
 * POST /grant-reward — JSON `{ "purpose", "idempotencyKey", "adVerified": true }` + `Authorization: Bearer <idToken>`.
 * **Ad verification** — `AD_VERIFICATION_MODE=client` (default): JSON `adVerified: true` after SDK reward (**spoofable MVP**).
 * `AD_VERIFICATION_MODE=ssv`: reserved (returns 501 until you implement SSV / mediation server grants).
 * **Next level:** AdMob SSV — Google POSTs to your HTTPS URL with signed payload; grant only after that webhook.
 * One rewarded ad ⇒ one reward only (no bundled credits + number + otp).
 * Idempotency doc id = sha256(`idempotencyKey` + ":" + `purpose`) so the same key cannot replay across purposes.
 * Fresh idempotency rows dedupe for `REWARD_IDEMPOTENCY_TTL_MS` (default 2m); older rows may be replaced on new grants.
 * - **call** — adds call credits (free: `REWARD_GRANT_CREDITS_FREE`, first lifetime call: `FIRST_AD_GRANT_CREDITS_FREE`; premium: premium rate + streak bonuses).
 * - **number** — `number_ads_progress += 1` (free, no assigned line, below cap).
 * - **otp** — `otp_ads_progress += 1` capped at `OTP_ADS_REQUIRED_PER_SMS` (free).
 * Premium: only `purpose: "call"` is allowed.
 */
app.post("/grant-reward", async (req, res) => {
  if (!firebaseAdmin) {
    return res.status(503).json({
      error: "Grant reward not configured (set FIREBASE_SERVICE_ACCOUNT_JSON on the server)",
    });
  }
  const auth = req.headers.authorization || "";
  const m = /^Bearer\s+(.+)$/i.exec(auth);
  if (!m) {
    return res.status(401).json({ error: "Missing Authorization: Bearer <Firebase ID token>" });
  }
  let uid;
  try {
    const dec = await firebaseAdmin.auth().verifyIdToken(m[1]);
    uid = dec.uid;
  } catch (e) {
    console.error("verifyIdToken:", e.message);
    return res.status(401).json({ error: "Invalid or expired token" });
  }

  const purposeIn = normalizeGrantPurpose(req.body != null ? req.body.purpose : undefined);
  if (!["call", "number", "otp"].includes(purposeIn)) {
    return res.status(400).json({
      error: "Invalid purpose",
      expected: ["call", "number", "otp"],
    });
  }

  const idemRaw = req.body != null ? req.body.idempotencyKey : undefined;
  const idemKey = String(idemRaw ?? "").trim();
  if (idemKey.length < 8 || idemKey.length > 128 || !/^[a-zA-Z0-9_-]+$/.test(idemKey)) {
    return res.status(400).json({
      error: "Missing or invalid idempotencyKey",
      hint: "Send 8–128 chars [A-Za-z0-9_-] per completed ad (e.g. UUID).",
    });
  }

  if (AD_VERIFICATION_MODE === "ssv") {
    return res.status(501).json({
      error: "AD_VERIFICATION_MODE=ssv not implemented",
      message:
        "Use server-side ad verification (e.g. AdMob SSV) to mint a short-lived grant token, then accept it here instead of client adVerified — or set AD_VERIFICATION_MODE=client.",
    });
  }

  const adVerified = req.body != null && req.body.adVerified === true;
  if (!adVerified) {
    return res.status(400).json({
      error: "Ad not verified",
      hint: "Send adVerified: true only after the rewarded ad SDK onUserEarnedReward (or equivalent). Future: AdMob SSV / ironSource server callbacks.",
    });
  }

  const { FieldValue, Timestamp } = firebaseAdmin.firestore;
  const db = firebaseAdmin.firestore();

  let out = {
    ok: true,
    deduped: false,
    purpose: purposeIn,
    creditsAdded: 0,
    baseCredits: 0,
    streakBonus: 0,
    streakCount: 0,
    adSubCounter: 0,
    adsWatchedToday: 0,
    remainingDailyAds: 0,
    firstLifetimeAd: false,
    numberAdsProgress: null,
    otpAdsProgress: null,
  };

  let grantFirstLifetimeAd = false;
  let postGrantLog = { result: "granted", reason: "ok", waitMs: 0 };

  try {
    await db.runTransaction(async (t) => {
      const ref = db.collection("users").doc(uid);
      const idKeyHash = crypto
        .createHash("sha256")
        .update(`${idemKey}:${purposeIn}`)
        .digest("hex");
      const keyRef = ref.collection("reward_keys").doc(idKeyHash);
      const statsRef = db.collection("user_stats").doc(uid);

      const doc = await t.get(ref);
      const keySnap = await t.get(keyRef);
      await t.get(statsRef);
      const txNowMs = Timestamp.now().toMillis();

      const d0 = doc.exists ? doc.data() : {};
      const keyAt0 = keySnap.exists ? rewardKeyAtMillis(keySnap.data()) : 0;
      const keyAgeMs = keyAt0 > 0 ? txNowMs - keyAt0 : Number.POSITIVE_INFINITY;
      // Fresh dedupe: same idKeyHash (includes purpose) within TTL. If stale/missing `at`, fall through — no cross-purpose
      // collision because doc id is purpose-scoped; `t.set` below writes a fresh `at` to reset the TTL window.
      if (keySnap.exists && keyAgeMs < REWARD_IDEMPOTENCY_TTL_MS) {
        const nowMs0 = txNowMs;
        const nowDate0 = new Date(nowMs0);
        const dayKey0 = utcDayKey(nowDate0);
        const prem0 = readEffectivePremiumUser(d0, nowDate0);
        const max0 = prem0 ? MAX_ADS_PER_DAY_PREMIUM : MAX_ADS_PER_DAY_FREE;
        const at0 = readAdsWatchedTodayAuthoritative(d0, dayKey0);
        out = {
          ok: true,
          deduped: true,
          message: "Reward already granted",
          purpose: purposeIn,
          creditsAdded: 0,
          baseCredits: 0,
          streakBonus: 0,
          streakCount: Number(d0.ad_streak_count || 0),
          adSubCounter: 0,
          adsWatchedToday: at0,
          remainingDailyAds: Math.max(0, max0 - at0),
          firstLifetimeAd: false,
          numberAdsProgress: readNumberAdsProgress(d0),
          otpAdsProgress: readOtpAdsProgress(d0),
        };
        grantFirstLifetimeAd = false;
        if (doc.exists) {
          let g0 = readGrantAttemptsToday(d0, dayKey0);
          if (String(d0.grant_attempts_day_key || "") !== dayKey0) g0 = 0;
          g0 += 1;
          t.update(ref, {
            grant_attempts_today: g0,
            grant_attempts_day_key: dayKey0,
          });
        }
        postGrantLog = { result: "deduped", reason: "ok", waitMs: 0 };
        return;
      }

      const nowMs = txNowMs;
      const now = new Date(nowMs);
      const dayKey = utcDayKey(now);

      const d = doc.exists ? doc.data() : {};
      if (!doc.exists && purposeIn !== "call") {
        throw Object.assign(new Error("User profile not found"), { http: 404 });
      }
      const premiumExpired = isPremiumSubscriptionExpired(d, now);
      const premium = readEffectivePremiumUser(d, now);

      if (premium && purposeIn !== "call") {
        throw Object.assign(new Error("Premium users only use purpose call"), { http: 400 });
      }

      const maxAds = premium ? MAX_ADS_PER_DAY_PREMIUM : MAX_ADS_PER_DAY_FREE;

      const lifetimeAdsBefore = Number(d.ads_watched_count ?? 0);
      grantFirstLifetimeAd = lifetimeAdsBefore === 0;

      let adsToday = readAdsWatchedTodayAuthoritative(d, dayKey);
      let storedDay = d.last_reset_date || d.adRewardsDayKey || "";
      if (storedDay !== dayKey) {
        adsToday = 0;
        storedDay = dayKey;
      }

      // Daily cap before cooldown so 429 body matches user expectation when both apply.
      if (adsToday >= maxAds) {
        throw Object.assign(new Error("Daily cap reached"), { http: 429 });
      }

      const gapSec = premium
        ? AD_GAP_SECONDS_PREMIUM
        : adsToday > 15
          ? 60
          : AD_GAP_SECONDS_FREE;
      const gapMs = gapSec * 1000;

      const lastMs = readLastAdGrantServerMs(d);
      if (lastMs > 0 && nowMs - lastMs < gapMs) {
        const waitMs = Math.max(1, Math.ceil(gapMs - (nowMs - lastMs)));
        const waitSeconds = Math.max(1, Math.ceil(waitMs / 1000));
        throw Object.assign(new Error("Cooldown active"), { http: 429, waitMs, waitSeconds });
      }

      const lastStreakDay = String(d.ad_streak_last_day || "");
      let streakCount = Number(d.ad_streak_count || 0);
      let streakBonus = 0;

      if (lastStreakDay !== dayKey) {
        const yesterdayKey = utcDayKeyAddDays(dayKey, -1);
        if (lastStreakDay === yesterdayKey) {
          streakCount += 1;
        } else {
          streakCount = 1;
        }
        if (premium && purposeIn === "call") {
          const mb = AD_STREAK_MILESTONE_BONUS[streakCount];
          if (mb != null) streakBonus = mb;
        }
      }

      let creditsAdded = 0;
      let baseCredits = 0;

      let paid = Number(d.paidCredits ?? 0);
      let reward = Number(d.rewardCredits ?? 0);
      if (d.paidCredits === undefined && d.credits != null) {
        paid = Number(d.credits);
        reward = 0;
      }
      const expTs = d.rewardCreditsExpiresAt;
      if (reward > 0 && expTs && expTs.toDate && expTs.toDate() < now) {
        paid += reward;
        reward = 0;
      }

      const firstCallBonusConsumed =
        d.first_call_reward_granted === true || d.firstCallRewardGranted === true;
      const firstCallBonusEligible =
        !premium &&
        purposeIn === "call" &&
        !firstCallBonusConsumed &&
        lifetimeAdsBefore === 0;

      if (purposeIn === "call") {
        const base = premium
          ? REWARD_GRANT_CREDITS_PREMIUM
          : firstCallBonusEligible
            ? FIRST_AD_GRANT_CREDITS_FREE
            : REWARD_GRANT_CREDITS_FREE;
        baseCredits = base;
        creditsAdded = baseCredits + streakBonus;
        reward += creditsAdded;
      }

      const adsTodayNew = adsToday + 1;

      let rewardExp = null;
      if (purposeIn === "call" && reward > 0) {
        if (creditsAdded > 0) {
          rewardExp = Timestamp.fromDate(new Date(now.getTime() + 24 * 60 * 60 * 1000));
        } else if (expTs && expTs.toDate && expTs.toDate() >= now) {
          rewardExp = expTs;
        } else {
          rewardExp = Timestamp.fromDate(new Date(now.getTime() + 24 * 60 * 60 * 1000));
        }
      }

      const grantTs = Timestamp.fromMillis(nowMs);
      const lifeAfterGrant = lifetimeAdsBefore + 1;
      const patch = {
        ad_sub_counter: 0,
        ad_progress: 0,
        adRewardCycleCount: 0,
        ads_watched_today: adsTodayNew,
        adRewardsCount: adsTodayNew,
        ads_watched_count: FieldValue.increment(1),
        last_reset_date: storedDay,
        adRewardsDayKey: storedDay,
        last_ad_timestamp: grantTs,
        lastAdWatchTime: grantTs,
        lastAdRewardAt: grantTs,
        last_ad_grant_server_ms: nowMs,
        ad_streak_count: streakCount,
        ad_streak_last_day: lastStreakDay === dayKey ? lastStreakDay : dayKey,
      };
      if (lifeAfterGrant > 100) {
        patch.is_high_value_user = true;
      }

      if (purposeIn === "call") {
        patch.paidCredits = paid;
        patch.rewardCredits = reward;
        patch.rewardCreditsExpiresAt = reward > 0 ? rewardExp : null;
        patch.credits = paid + reward;
        if (firstCallBonusEligible && creditsAdded > 0) {
          patch.first_call_reward_granted = true;
        }
        if (creditsAdded > 0) {
          patch.last_grant_reward_at = FieldValue.serverTimestamp();
          patch.last_grant_at_ads_watched_today = adsTodayNew;
        }

        const assignedForRenew = String(d.assigned_number ?? "").trim();
        let renewProg = Number(d.number_renew_ad_progress || 0);
        if (assignedForRenew && assignedForRenew.toLowerCase() !== "none") {
          const expR = readNumberExpiryDate(d);
          if (!expR || expR.getTime() - now.getTime() <= 7 * 86400000) {
            renewProg = Math.min(NUMBER_RENEW_ADS_REQUIRED, renewProg + 1);
          } else {
            renewProg = 0;
          }
        } else {
          renewProg = 0;
        }
        patch.number_renew_ad_progress = renewProg;
      }

      if (purposeIn === "number") {
        const assignedStr = String(d.assigned_number ?? "").trim();
        const hasAssignedLine = assignedStr && assignedStr.toLowerCase() !== "none";
        if (hasAssignedLine) {
          throw Object.assign(new Error("Number already assigned"), { http: 400 });
        }
        const numProg = readNumberAdsProgress(d);
        if (numProg >= NUMBER_UNLOCK_ADS_REQUIRED) {
          throw Object.assign(new Error("Number unlock already complete"), { http: 400 });
        }
        const numProgOut = Math.max(
          0,
          Math.min(NUMBER_UNLOCK_ADS_REQUIRED, Math.floor(numProg) + 1),
        );
        patch.number_ads_progress = numProgOut;
      }

      if (purposeIn === "otp") {
        const otpProg = readOtpAdsProgress(d);
        if (otpProg >= OTP_ADS_REQUIRED_PER_SMS) {
          throw Object.assign(new Error("OTP ads bank full — send an SMS first"), { http: 400 });
        }
        const otpProgOut = Math.max(
          0,
          Math.min(OTP_ADS_REQUIRED_PER_SMS, Math.floor(otpProg) + 1),
        );
        patch.otp_ads_progress = otpProgOut;
      }

      if (lastStreakDay === dayKey) {
        delete patch.ad_streak_count;
        delete patch.ad_streak_last_day;
      }

      if (premiumExpired) {
        Object.assign(patch, PREMIUM_SUBSCRIPTION_DEMOTE_FIELDS);
      }

      let ga = readGrantAttemptsToday(d, dayKey);
      if (String(d.grant_attempts_day_key || "") !== dayKey) ga = 0;
      ga += 1;
      patch.grant_attempts_today = ga;
      patch.grant_attempts_day_key = dayKey;

      const keysCol = ref.collection("reward_keys");
      // If deploy warns, ensure `users/*/reward_keys` has a single-field index on `at` ascending (often auto-created).
      const keysSnap = await t.get(keysCol.orderBy("at", "asc").limit(51));
      const ringSize = keysSnap.size;
      if (ringSize >= 50) {
        const toDelete = keysSnap.docs.slice(0, ringSize - 49);
        for (const kdoc of toDelete) {
          t.delete(kdoc.ref);
        }
      }

      // idKeyHash = sha256(idemKey + ":" + purpose) → different purposes never share a doc. Stale TTL overwrites
      // always use fresh server millis on `at` so the dedupe TTL window resets from this write.
      const rewardKeyAtMs = Timestamp.now().toMillis();
      t.set(keyRef, {
        at: Timestamp.fromMillis(rewardKeyAtMs),
        purpose: purposeIn,
        idKeyHash,
      });
      if (doc.exists) {
        t.update(ref, patch);
      } else {
        t.set(ref, patch, { merge: true });
      }

      const creditsInt = Math.max(0, Math.floor(Number(creditsAdded) || 0));
      const costInc = Number.isFinite(EST_COST_INR_PER_REWARDED_AD)
        ? EST_COST_INR_PER_REWARDED_AD
        : 0;
      const revInc = Number.isFinite(EST_REVENUE_INR_PER_REWARDED_AD)
        ? EST_REVENUE_INR_PER_REWARDED_AD
        : 0;
      // `user_stats/{uid}`: this path — ads/credits/revenue micro + cost micro. Twilio: `settleOutboundCallBill` →
      // `total_call_minutes` + call cost; `POST /send-sms` → `total_sms_sent` + SMS cost; assign-number success →
      // `total_number_cost` + same into `total_cost_estimated`.
      t.set(
        statsRef,
        {
          total_ads_watched: FieldValue.increment(1),
          total_credits_given: FieldValue.increment(creditsInt),
          total_estimated_ad_revenue_inr: FieldValue.increment(revInc),
          total_cost_estimated: FieldValue.increment(costInc),
          stats_updated_at: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );

      const numOut =
        purposeIn === "number" ? patch.number_ads_progress : readNumberAdsProgress(d);
      const otpOut = purposeIn === "otp" ? patch.otp_ads_progress : readOtpAdsProgress(d);

      out = {
        ok: true,
        deduped: false,
        purpose: purposeIn,
        creditsAdded,
        baseCredits,
        streakBonus,
        streakCount,
        adSubCounter: 0,
        adsWatchedToday: adsTodayNew,
        remainingDailyAds: Math.max(0, maxAds - adsTodayNew),
        firstLifetimeAd: grantFirstLifetimeAd,
        numberAdsProgress: numOut,
        otpAdsProgress: otpOut,
      };
      postGrantLog = { result: "granted", reason: "ok", waitMs: 0 };
    });
    if (postGrantLog.result === "deduped") {
      bumpGrantRewardMetric("deduped_count");
    } else {
      bumpGrantRewardMetric("granted_count");
    }
    const mSnap = grantRewardMetricSnapshot();
    console.info("grant-reward", {
      uid,
      purpose: purposeIn,
      result: postGrantLog.result,
      reason: postGrantLog.reason,
      waitMs: postGrantLog.waitMs,
      granted_count: mSnap.granted_count,
      deduped_count: mSnap.deduped_count,
      blocked_cooldown_count: mSnap.blocked_cooldown_count,
      blocked_daily_cap_count: mSnap.blocked_daily_cap_count,
    });
  } catch (e) {
    const code = e.http || 500;
    if (code === 429) {
      if (String(e.message || "").includes("Daily cap")) {
        await incrementGrantAttemptsTodayForUid(uid);
        bumpGrantRewardMetric("blocked_daily_cap_count");
        const mSnapD = grantRewardMetricSnapshot();
        console.info("grant-reward", {
          uid,
          purpose: purposeIn,
          result: "blocked",
          reason: "daily_cap",
          waitMs: 0,
          granted_count: mSnapD.granted_count,
          deduped_count: mSnapD.deduped_count,
          blocked_cooldown_count: mSnapD.blocked_cooldown_count,
          blocked_daily_cap_count: mSnapD.blocked_daily_cap_count,
        });
        return res.status(429).json({
          error: "Daily cap reached",
          reason: "daily_cap",
          waitMs: 0,
          waitSeconds: 0,
          retryAfterSeconds: 0,
        });
      }
      if (e.waitSeconds != null || e.waitMs != null) {
        await incrementGrantAttemptsTodayForUid(uid);
        bumpGrantRewardMetric("blocked_cooldown_count");
        const ws =
          e.waitSeconds != null
            ? e.waitSeconds
            : Math.max(1, Math.ceil(Number(e.waitMs || 0) / 1000));
        const wm =
          e.waitMs != null ? Number(e.waitMs) : Math.max(1000, ws * 1000);
        const mSnapC = grantRewardMetricSnapshot();
        console.info("grant-reward", {
          uid,
          purpose: purposeIn,
          result: "blocked",
          reason: "cooldown",
          waitMs: wm,
          granted_count: mSnapC.granted_count,
          deduped_count: mSnapC.deduped_count,
          blocked_cooldown_count: mSnapC.blocked_cooldown_count,
          blocked_daily_cap_count: mSnapC.blocked_daily_cap_count,
        });
        res.set("Retry-After", String(Math.ceil(wm / 1000)));
        res.set("Retry-After-Ms", String(Math.ceil(wm)));
        return res.status(429).json({
          error: "Cooldown active",
          reason: "cooldown",
          message: `Please wait ${ws} second(s) since the last ad.`,
          waitSeconds: ws,
          waitMs: wm,
          retryAfterSeconds: ws,
        });
      }
      await incrementGrantAttemptsTodayForUid(uid);
      const mSnapR = grantRewardMetricSnapshot();
      console.info("grant-reward", {
        uid,
        purpose: purposeIn,
        result: "blocked",
        reason: "rate_limited",
        waitMs: 0,
        granted_count: mSnapR.granted_count,
        deduped_count: mSnapR.deduped_count,
        blocked_cooldown_count: mSnapR.blocked_cooldown_count,
        blocked_daily_cap_count: mSnapR.blocked_daily_cap_count,
      });
      return res.status(429).json({ error: String(e.message || "Too many requests") });
    }
    if (code >= 400 && code < 500) {
      return res.status(code).json({ error: String(e.message || e) });
    }
    console.error("grant-reward tx:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }
  return res.status(200).json(out);
});

/** `PAYWALL_EXPERIMENT` wins over legacy `PAYWALL_VARIANT`. Values: A | B | AB | PRICE3 */
function getPaywallExperimentEnv() {
  return String(process.env.PAYWALL_EXPERIMENT || process.env.PAYWALL_VARIANT || "A")
    .trim()
    .toUpperCase();
}

/**
 * Sticky bucket once per user (`paywall_ab_bucket` / `paywall_price_tier`) when mode is AB / PRICE3.
 * @returns {{ ab: string, tier: string }}
 */
async function ensurePaywallExperimentAssignment(uid) {
  const exp = getPaywallExperimentEnv();
  const db = firebaseAdmin.firestore();
  const ref = db.collection("users").doc(uid);
  const snap = await ref.get();
  if (!snap.exists) {
    return { ab: exp === "B" ? "B" : "A", tier: exp === "PRICE3" ? "mid" : "" };
  }
  const d = snap.data() || {};
  const updates = {};
  let ab = String(d.paywall_ab_bucket || "").toUpperCase();
  let tier = String(d.paywall_price_tier || "").toLowerCase();

  if (exp === "PRICE3") {
    if (tier !== "cheap" && tier !== "mid" && tier !== "high") {
      const r = Math.floor(Math.random() * 3);
      tier = r === 0 ? "cheap" : r === 1 ? "mid" : "high";
      updates.paywall_price_tier = tier;
    }
  } else if (exp === "AB") {
    if (ab !== "A" && ab !== "B") {
      ab = Math.random() < 0.5 ? "A" : "B";
      updates.paywall_ab_bucket = ab;
    }
  } else if (exp === "B") {
    ab = "B";
    if (d.paywall_ab_bucket !== "B") updates.paywall_ab_bucket = "B";
  } else {
    ab = "A";
    if (d.paywall_ab_bucket && String(d.paywall_ab_bucket).toUpperCase() !== "A") {
      updates.paywall_ab_bucket = "A";
    } else if (!d.paywall_ab_bucket) {
      updates.paywall_ab_bucket = "A";
    }
  }

  if (Object.keys(updates).length) {
    await ref.set(updates, { merge: true });
  }

  if (exp === "PRICE3") {
    const t2 = String(
      (updates.paywall_price_tier ?? d.paywall_price_tier ?? tier) || "mid",
    ).toLowerCase();
    const tierOut = ["cheap", "mid", "high"].includes(t2) ? t2 : "mid";
    return { ab: "A", tier: tierOut };
  }
  if (exp === "AB") {
    const a2 = String((updates.paywall_ab_bucket ?? d.paywall_ab_bucket ?? ab) || "A").toUpperCase();
    return { ab: a2 === "B" ? "B" : "A", tier: "" };
  }
  return { ab: exp === "B" ? "B" : "A", tier: "" };
}

/** Suffix for `total_paywall_*_{suffix}` — must match paywall-config buckets. */
function paywallMetricSuffixFromUserData(d) {
  const exp = getPaywallExperimentEnv();
  if (exp === "PRICE3") {
    const tier = String(d?.paywall_price_tier || "").toLowerCase();
    if (tier === "cheap" || tier === "mid" || tier === "high") return tier;
    return "mid";
  }
  if (exp === "AB") {
    const ab = String(d?.paywall_ab_bucket || "A").toUpperCase();
    return ab === "B" ? "B" : "A";
  }
  return exp === "B" ? "B" : "A";
}

/**
 * @param {{ ab: string, tier: string }} p
 */
function buildPaywallConfigPayload({ ab, tier }) {
  const exp = getPaywallExperimentEnv();
  const ctaLabel = String(process.env.PAYWALL_CTA_LABEL || "View packs").trim() || "View packs";
  if (exp === "PRICE3" && (tier === "cheap" || tier === "mid" || tier === "high")) {
    const priceCheap = Number(process.env.PAYWALL_PRICE_CHEAP ?? 39);
    const priceMid = Number(process.env.PAYWALL_PRICE_MID ?? 59);
    const priceHigh = Number(process.env.PAYWALL_PRICE_HIGH ?? 79);
    const pNum = tier === "cheap" ? priceCheap : tier === "high" ? priceHigh : priceMid;
    const priceFloor = Number.isFinite(pNum)
      ? Math.floor(pNum)
      : tier === "cheap"
        ? 39
        : tier === "high"
          ? 79
          : 59;
    const threshold = Number(
      tier === "cheap"
        ? process.env.PAYWALL_THRESHOLD_CHEAP ?? 35
        : tier === "high"
          ? process.env.PAYWALL_THRESHOLD_HIGH ?? 45
          : process.env.PAYWALL_THRESHOLD_MID ?? 40,
    );
    const saveHint = String(
      tier === "cheap"
        ? process.env.PAYWALL_SAVE_HINT_CHEAP || process.env.PAYWALL_SAVE_HINT || ""
        : tier === "high"
          ? process.env.PAYWALL_SAVE_HINT_HIGH || process.env.PAYWALL_SAVE_HINT || ""
          : process.env.PAYWALL_SAVE_HINT_MID || process.env.PAYWALL_SAVE_HINT || "",
    ).trim();
    return {
      experiment: "PRICE3",
      variant: tier,
      metricBucket: tier,
      lifetimeAdsThreshold: Number.isFinite(threshold) ? Math.max(1, Math.floor(threshold)) : 40,
      priceLabel: `₹${priceFloor}`,
      saveVsAdsHint: saveHint,
      ctaLabel,
    };
  }
  const isB = exp === "B" || (exp === "AB" && ab === "B");
  const threshold = Number(
    isB ? process.env.PAYWALL_THRESHOLD_B ?? 30 : process.env.PAYWALL_THRESHOLD_A ?? 40,
  );
  const priceNum = Number(
    isB ? process.env.PAYWALL_PRICE_B ?? 49 : process.env.PAYWALL_PRICE_A ?? 59,
  );
  const priceFloor = Number.isFinite(priceNum) ? Math.floor(priceNum) : isB ? 49 : 59;
  const saveHint = String(process.env.PAYWALL_SAVE_HINT || "").trim();
  const modeLabel = exp === "AB" ? "AB" : isB ? "B" : "A";
  return {
    experiment: modeLabel,
    variant: isB ? "B" : "A",
    metricBucket: isB ? "B" : "A",
    lifetimeAdsThreshold: Number.isFinite(threshold) ? Math.max(1, Math.floor(threshold)) : isB ? 30 : 40,
    priceLabel: `₹${priceFloor}`,
    saveVsAdsHint: saveHint,
    ctaLabel,
  };
}

app.get("/paywall-config", async (req, res) => {
  const exp = getPaywallExperimentEnv();
  let ab = exp === "B" ? "B" : "A";
  let tier = exp === "PRICE3" ? "mid" : "";
  if (firebaseAdmin) {
    const auth = req.headers.authorization || "";
    const m = /^Bearer\s+(.+)$/i.exec(auth);
    if (m) {
      try {
        const uid = (await firebaseAdmin.auth().verifyIdToken(m[1])).uid;
        const a = await ensurePaywallExperimentAssignment(uid);
        ab = a.ab;
        tier = a.tier || (exp === "PRICE3" ? "mid" : "");
      } catch (_) {
        /* invalid token → defaults */
      }
    }
  }
  return res.status(200).json(buildPaywallConfigPayload({ ab, tier }));
});

/** AdMob SSV — placeholder until signature verification + minted grants are implemented. */
app.get("/ad-ssv-callback", (_req, res) => {
  return res
    .status(501)
    .type("text/plain")
    .send(
      "SSV stub — implement Google rewarded SSV (query signature + user_id) then mint server-side grant; set AD_VERIFICATION_MODE=ssv when ready.",
    );
});

/**
 * Idempotent paywall funnel write: `user_stats/{uid}/paywall_metric_dedupe/{eventId}` (retry-safe).
 * @param {string} uid
 * @param {"impression"|"intent_click"|"conversion"} type
 * @param {string} eventId
 */
async function recordPaywallMetricDeduped(uid, type, eventId) {
  if (!firebaseAdmin) {
    throw new Error("Firebase Admin not configured");
  }
  const db = firebaseAdmin.firestore();
  const { FieldValue } = firebaseAdmin.firestore;
  const statsRef = db.collection("user_stats").doc(uid);
  const dedupeRef = statsRef.collection("paywall_metric_dedupe").doc(eventId);
  let deduped = false;
  await db.runTransaction(async (t) => {
    const userRef = db.collection("users").doc(uid);
    const userSnap = await t.get(userRef);
    const dedupeSnap = await t.get(dedupeRef);
    if (dedupeSnap.exists) {
      deduped = true;
      return;
    }
    const ud = userSnap.exists ? userSnap.data() : {};
    const sk = paywallMetricSuffixFromUserData(ud);
    t.set(dedupeRef, { at: FieldValue.serverTimestamp(), type, bucket: sk });
    const patch = {
      stats_updated_at: FieldValue.serverTimestamp(),
    };
    if (type === "impression") {
      patch.total_paywall_impressions = FieldValue.increment(1);
      patch[`total_paywall_impressions_${sk}`] = FieldValue.increment(1);
    } else if (type === "intent_click") {
      patch.total_paywall_intent_clicks = FieldValue.increment(1);
      patch[`total_paywall_intent_clicks_${sk}`] = FieldValue.increment(1);
    } else {
      patch.total_paywall_conversions = FieldValue.increment(1);
      patch[`total_paywall_conversions_${sk}`] = FieldValue.increment(1);
    }
    t.set(statsRef, patch, { merge: true });
  });
  return { deduped };
}

/**
 * POST /record-paywall — Firebase Bearer; JSON `{ "type", "eventId" }`.
 * `type`: impression | intent_click (View packs) | conversion (reserved; also set from verify-payment).
 * Dedupes by `eventId` under `user_stats/{uid}/paywall_metric_dedupe/{eventId}`.
 */
app.post("/record-paywall", async (req, res) => {
  if (!firebaseAdmin) {
    return res.status(503).json({ error: "Firebase Admin not configured" });
  }
  const uid = await getUidFromBearer(req, res);
  if (!uid) return;
  const eventId = String(req.body != null ? req.body.eventId : "")
    .trim();
  if (eventId.length < 8 || eventId.length > 128 || !/^[a-zA-Z0-9_-]+$/.test(eventId)) {
    return res.status(400).json({
      error: "Missing or invalid eventId",
      hint: "Send 8–128 chars [A-Za-z0-9_-] per event (e.g. UUID) so retries do not double-count.",
    });
  }
  const type = String(req.body != null ? req.body.type : "")
    .trim()
    .toLowerCase();
  if (!["impression", "intent_click", "conversion"].includes(type)) {
    return res.status(400).json({
      error: "Invalid type",
      expected: ["impression", "intent_click", "conversion"],
    });
  }
  try {
    const { deduped } = await recordPaywallMetricDeduped(uid, type, eventId);
    return res.status(200).json({ ok: true, deduped });
  } catch (e) {
    console.error("record-paywall:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }
});

/**
 * POST /claim-welcome-bonus — **disabled** (no free login credits).
 * Legacy clients may still call; response is always no grant, no Firestore writes.
 */
app.post("/claim-welcome-bonus", (_req, res) => {
  return res.status(200).json({ granted: false, reason: "disabled" });
});

/** Matches Flutter `_planCheckouts` amounts (INR paise / USD cents). */
const SUBSCRIPTION_PLAN_AMOUNTS_INR = {
  daily: 8300,
  weekly: 41500,
  /** ₹349 / month — within ₹299–₹399 product band. */
  monthly: 34900,
  /** ₹1149 / year — within ₹999–₹1299 product band. */
  yearly: 114900,
  /** Starter credit pack — ₹59 (120–150 credits on grant). */
  starter_credits: 5900,
  credit_pack_small: 4900,
  credit_pack_medium: 9900,
  credit_pack_large: 19900,
};
const SUBSCRIPTION_PLAN_AMOUNTS_USD = {
  daily: 99,
  weekly: 499,
  monthly: 499,
  yearly: 12999,
  starter_credits: 99,
  credit_pack_small: 49,
  credit_pack_medium: 99,
  credit_pack_large: 199,
};

/** Credits added to `paidCredits` on successful verify for each pack plan_key. */
const CREDIT_PACK_CREDITS = {
  credit_pack_small: 100,
  credit_pack_medium: 250,
  credit_pack_large: 600,
};

const PREMIUM_WELCOME_BONUS = Number(process.env.PREMIUM_WELCOME_BONUS || 100);
const STARTER_PACK_CREDITS = Number(process.env.STARTER_PACK_CREDITS || 80);
const PREMIUM_MONTHLY_BONUS_CREDITS = Number(process.env.PREMIUM_MONTHLY_BONUS_CREDITS || 200);

function subscriptionExpiryFromPlan(plan) {
  const now = Date.now();
  switch (plan) {
    case "daily":
      return new Date(now + 86400000);
    case "weekly":
      return new Date(now + 604800000);
    case "monthly":
      return new Date(now + 2592000000);
    case "yearly":
      return new Date(now + 31536000000);
    default:
      return new Date(now + 2592000000);
  }
}

function verifyRazorpayPaymentSignature(orderId, paymentId, signature, secret) {
  const body = String(orderId) + "|" + String(paymentId);
  const expected = crypto.createHmac("sha256", secret).update(body).digest("hex");
  const sig = String(signature ?? "").trim();
  if (expected.length !== sig.length) {
    return false;
  }
  try {
    return crypto.timingSafeEqual(Buffer.from(expected, "utf8"), Buffer.from(sig, "utf8"));
  } catch {
    return false;
  }
}

let _rzpSingleton = null;
function getRazorpaySdk() {
  const keyId = process.env.RAZORPAY_KEY_ID;
  const keySecret = process.env.RAZORPAY_KEY_SECRET;
  if (!keyId || !String(keyId).trim() || !keySecret || !String(keySecret).trim()) {
    return null;
  }
  if (!_rzpSingleton) {
    _rzpSingleton = new Razorpay({
      key_id: String(keyId).trim(),
      key_secret: String(keySecret).trim(),
    });
  }
  return _rzpSingleton;
}

/**
 * POST /create-subscription-order — Firebase Bearer; body `{ "plan": "daily"|… }`.
 * Creates a Razorpay Order; Flutter opens Checkout with `order_id` + returned amount.
 */
app.post("/create-subscription-order", async (req, res) => {
  if (!firebaseAdmin) {
    return res.status(503).json({ error: "Firebase Admin not configured (set FIREBASE_SERVICE_ACCOUNT_JSON)" });
  }
  const rzp = getRazorpaySdk();
  if (!rzp) {
    return res.status(503).json({
      error: "Razorpay not configured on server (set RAZORPAY_KEY_ID and RAZORPAY_KEY_SECRET)",
    });
  }
  const auth = req.headers.authorization || "";
  const m = /^Bearer\s+(.+)$/i.exec(auth);
  if (!m) {
    return res.status(401).json({ error: "Missing Authorization: Bearer <Firebase ID token>" });
  }
  let uid;
  try {
    uid = (await firebaseAdmin.auth().verifyIdToken(m[1])).uid;
  } catch (e) {
    console.error("verifyIdToken (create-subscription-order):", e.message);
    return res.status(401).json({ error: "Invalid or expired token" });
  }
  const plan = normalizePlanType(req.body && req.body.plan);
  if (!plan) {
    return res.status(400).json({
      error: "Missing or invalid plan",
      expected: ["daily", "weekly", "monthly", "yearly", "starter_credits"],
    });
  }
  const currency = String(process.env.RAZORPAY_CURRENCY || "INR")
    .trim()
    .toUpperCase();
  const amount =
    currency === "USD"
      ? SUBSCRIPTION_PLAN_AMOUNTS_USD[plan]
      : SUBSCRIPTION_PLAN_AMOUNTS_INR[plan];
  if (amount == null || !Number.isFinite(amount)) {
    return res.status(500).json({ error: "Unknown amount for plan/currency" });
  }
  const keyId = String(process.env.RAZORPAY_KEY_ID).trim();
  const receipt = `tf_${uid.slice(0, 12)}_${plan}_${Date.now()}`.slice(0, 40);
  try {
    const order = await rzp.orders.create({
      amount,
      currency,
      receipt,
      notes: {
        firebase_uid: uid,
        plan_key: plan,
      },
    });
    return res.status(200).json({
      orderId: order.id,
      amount: Number(order.amount),
      currency: order.currency,
      keyId,
    });
  } catch (e) {
    console.error("create-subscription-order:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }
});

/**
 * POST /purchase-credits-pack — Firebase Bearer; JSON `{ "pack": "small"|"medium"|"large" }`.
 * Creates a Razorpay Order (same shape as create-subscription-order); verify via POST /verify-payment.
 */
app.post("/purchase-credits-pack", async (req, res) => {
  if (!firebaseAdmin) {
    return res.status(503).json({ error: "Firebase Admin not configured (set FIREBASE_SERVICE_ACCOUNT_JSON)" });
  }
  const rzp = getRazorpaySdk();
  if (!rzp) {
    return res.status(503).json({
      error: "Razorpay not configured on server (set RAZORPAY_KEY_ID and RAZORPAY_KEY_SECRET)",
    });
  }
  const auth = req.headers.authorization || "";
  const m = /^Bearer\s+(.+)$/i.exec(auth);
  if (!m) {
    return res.status(401).json({ error: "Missing Authorization: Bearer <Firebase ID token>" });
  }
  let uid;
  try {
    uid = (await firebaseAdmin.auth().verifyIdToken(m[1])).uid;
  } catch (e) {
    console.error("verifyIdToken (purchase-credits-pack):", e.message);
    return res.status(401).json({ error: "Invalid or expired token" });
  }
  const pack = String(req.body && req.body.pack != null ? req.body.pack : "")
    .trim()
    .toLowerCase();
  const planKey =
    pack === "small"
      ? "credit_pack_small"
      : pack === "medium"
        ? "credit_pack_medium"
        : pack === "large"
          ? "credit_pack_large"
          : null;
  if (!planKey) {
    return res.status(400).json({
      error: "Missing or invalid pack",
      expected: ["small", "medium", "large"],
    });
  }
  const currency = String(process.env.RAZORPAY_CURRENCY || "INR")
    .trim()
    .toUpperCase();
  const amount =
    currency === "USD"
      ? SUBSCRIPTION_PLAN_AMOUNTS_USD[planKey]
      : SUBSCRIPTION_PLAN_AMOUNTS_INR[planKey];
  if (amount == null || !Number.isFinite(amount)) {
    return res.status(500).json({ error: "Unknown amount for pack/currency" });
  }
  const keyId = String(process.env.RAZORPAY_KEY_ID).trim();
  const receipt = `tf_cp_${uid.slice(0, 10)}_${pack}_${Date.now()}`.slice(0, 40);
  try {
    const order = await rzp.orders.create({
      amount,
      currency,
      receipt,
      notes: {
        firebase_uid: uid,
        plan_key: planKey,
      },
    });
    return res.status(200).json({
      orderId: order.id,
      amount: Number(order.amount),
      currency: order.currency,
      keyId,
      planKey,
    });
  } catch (e) {
    console.error("purchase-credits-pack:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }
});

/**
 * POST /verify-payment — Firebase Bearer; body:
 * `{ "razorpay_payment_id", "razorpay_order_id", "razorpay_signature" }`
 * Verifies HMAC (official Razorpay method), fetches payment + order from Razorpay, updates Firestore via Admin only.
 */
app.post("/verify-payment", async (req, res) => {
  if (!firebaseAdmin) {
    return res.status(503).json({ error: "Firebase Admin not configured (set FIREBASE_SERVICE_ACCOUNT_JSON)" });
  }
  const keySecret = process.env.RAZORPAY_KEY_SECRET;
  if (!keySecret || !String(keySecret).trim()) {
    return res.status(503).json({ error: "RAZORPAY_KEY_SECRET not set on server" });
  }
  const rzp = getRazorpaySdk();
  if (!rzp) {
    return res.status(503).json({ error: "Razorpay SDK not configured" });
  }
  const auth = req.headers.authorization || "";
  const m = /^Bearer\s+(.+)$/i.exec(auth);
  if (!m) {
    return res.status(401).json({ error: "Missing Authorization: Bearer <Firebase ID token>" });
  }
  let uid;
  try {
    uid = (await firebaseAdmin.auth().verifyIdToken(m[1])).uid;
  } catch (e) {
    console.error("verifyIdToken (verify-payment):", e.message);
    return res.status(401).json({ error: "Invalid or expired token" });
  }

  const razorpay_payment_id = String(req.body?.razorpay_payment_id ?? "").trim();
  const razorpay_order_id = String(req.body?.razorpay_order_id ?? "").trim();
  const razorpay_signature = String(req.body?.razorpay_signature ?? "").trim();
  if (!razorpay_payment_id || !razorpay_order_id || !razorpay_signature) {
    return res.status(400).json({
      error: "Missing razorpay_payment_id, razorpay_order_id, or razorpay_signature",
    });
  }

  if (!verifyRazorpayPaymentSignature(razorpay_order_id, razorpay_payment_id, razorpay_signature, String(keySecret).trim())) {
    return res.status(400).json({ error: "Invalid payment signature" });
  }

  let payment;
  try {
    payment = await rzp.payments.fetch(razorpay_payment_id);
  } catch (e) {
    console.error("verify-payment fetch payment:", e);
    return res.status(502).json({ error: "Could not verify payment with Razorpay" });
  }
  if (String(payment.order_id || "") !== razorpay_order_id) {
    return res.status(400).json({ error: "Payment does not match order" });
  }
  const okStatus = payment.status === "authorized" || payment.status === "captured";
  if (!okStatus) {
    return res.status(400).json({ error: `Payment not successful (status=${payment.status})` });
  }

  let order;
  try {
    order = await rzp.orders.fetch(razorpay_order_id);
  } catch (e) {
    console.error("verify-payment fetch order:", e);
    return res.status(400).json({ error: "Could not load order" });
  }
  const notes = order.notes || {};
  if (String(notes.firebase_uid || "") !== uid) {
    return res.status(403).json({ error: "Order does not belong to this user" });
  }
  const plan = normalizePlanType(notes.plan_key);
  if (!plan) {
    return res.status(400).json({ error: "Invalid order metadata (plan)" });
  }
  const currency = String(process.env.RAZORPAY_CURRENCY || "INR")
    .trim()
    .toUpperCase();
  const expectedAmount =
    currency === "USD"
      ? SUBSCRIPTION_PLAN_AMOUNTS_USD[plan]
      : SUBSCRIPTION_PLAN_AMOUNTS_INR[plan];
  if (Number(payment.amount) !== expectedAmount) {
    return res.status(400).json({ error: "Amount mismatch for plan" });
  }
  if (String(payment.currency || "").toUpperCase() !== currency) {
    return res.status(400).json({ error: "Currency mismatch" });
  }

  const db = firebaseAdmin.firestore();
  const ref = db.collection("users").doc(uid);
  const { FieldValue, Timestamp } = firebaseAdmin.firestore;

  try {
    const out = await db.runTransaction(async (t) => {
      const snap = await t.get(ref);
      if (!snap.exists) {
        throw Object.assign(new Error("User document not found"), { http: 404 });
      }
      const d = snap.data() || {};
      const existingPid = String(d.last_razorpay_payment_id ?? "").trim();
      if (existingPid && existingPid === razorpay_payment_id) {
        return { ok: true, idempotent: true, plan };
      }

      let paid = Number(d.paidCredits ?? 0);
      let reward = Number(d.rewardCredits ?? 0);
      if (d.paidCredits === undefined && d.credits != null) {
        paid = Number(d.credits);
        reward = 0;
      }
      const expTs = d.rewardCreditsExpiresAt;
      const now = new Date();
      if (reward > 0 && expTs && expTs.toDate && expTs.toDate() < now) {
        paid += reward;
        reward = 0;
      }
      if (plan === "starter_credits") {
        paid += STARTER_PACK_CREDITS;
        const total = paid + reward;
        t.update(ref, {
          last_razorpay_payment_id: razorpay_payment_id,
          paidCredits: paid,
          rewardCredits: reward,
          rewardCreditsExpiresAt: reward > 0 ? expTs : null,
          credits: total,
        });
        return {
          ok: true,
          idempotent: false,
          plan,
          starterCreditsAdded: STARTER_PACK_CREDITS,
          welcomeBonus: 0,
        };
      }

      const packCredits = CREDIT_PACK_CREDITS[plan];
      if (packCredits != null && Number.isFinite(packCredits) && packCredits > 0) {
        paid += packCredits;
        const total = paid + reward;
        t.update(ref, {
          last_razorpay_payment_id: razorpay_payment_id,
          paidCredits: paid,
          rewardCredits: reward,
          rewardCreditsExpiresAt: reward > 0 ? expTs : null,
          credits: total,
        });
        return {
          ok: true,
          idempotent: false,
          plan,
          creditPackCreditsAdded: packCredits,
          welcomeBonus: 0,
        };
      }

      let bonus = 0;
      if (d.premiumWelcomeBonusGranted !== true && PREMIUM_WELCOME_BONUS > 0) {
        bonus = PREMIUM_WELCOME_BONUS;
        paid += bonus;
      }
      const total = paid + reward;
      const expDate = subscriptionExpiryFromPlan(plan);
      const premiumPatch = {
        isPremium: true,
        subscription_tier: "premium",
        subscriptionTier: "premium",
        premium_plan_type: plan,
        number_expiry_date: Timestamp.fromDate(expDate),
        expiry_date: Timestamp.fromDate(expDate),
        numberExpiry: Timestamp.fromDate(expDate),
        premium_subscribed_at: FieldValue.serverTimestamp(),
        last_razorpay_payment_id: razorpay_payment_id,
        premiumWelcomeBonusGranted: true,
        paidCredits: paid,
        rewardCredits: reward,
        rewardCreditsExpiresAt: reward > 0 ? expTs : null,
        credits: total,
      };
      t.update(ref, premiumPatch);
      return { ok: true, idempotent: false, plan, welcomeBonus: bonus };
    });
    if (!out.idempotent) {
      try {
        const { FieldValue: Fv } = firebaseAdmin.firestore;
        const statsRef = db.collection("user_stats").doc(uid);
        const cur = String(process.env.RAZORPAY_CURRENCY || "INR")
          .trim()
          .toUpperCase();
        if (cur === "INR") {
          const inr = Number(payment.amount) / 100;
          if (Number.isFinite(inr) && inr > 0) {
            await statsRef.set(
              {
                total_user_revenue_inr: Fv.increment(inr),
                stats_updated_at: Fv.serverTimestamp(),
              },
              { merge: true },
            );
          }
        }
      } catch (e) {
        console.warn("total_user_revenue_inr (verify-payment):", e.message || e);
      }
      try {
        await recordPaywallMetricDeduped(uid, "conversion", `vp_${razorpay_payment_id}`);
      } catch (e) {
        console.warn("record-paywall conversion (verify-payment):", e.message || e);
      }
    }
    return res.status(200).json(out);
  } catch (e) {
    const code = e.http || 500;
    console.error("verify-payment tx:", e);
    return res.status(code >= 400 && code < 600 ? code : 500).json({
      error: String(e.message || e),
    });
  }
});

/**
 * POST /claim-premium-monthly-bonus — Firebase Bearer; grants recurring premium credits (~monthly).
 * Idempotent within the same calendar month (UTC) using `lastMonthlyBonus` / `last_monthly_bonus_at`.
 */
app.post("/claim-premium-monthly-bonus", async (req, res) => {
  if (!firebaseAdmin) {
    return res.status(503).json({ error: "Firebase Admin not configured" });
  }
  const auth = req.headers.authorization || "";
  const m = /^Bearer\s+(.+)$/i.exec(auth);
  if (!m) {
    return res.status(401).json({ error: "Missing Authorization: Bearer <Firebase ID token>" });
  }
  let uid;
  try {
    uid = (await firebaseAdmin.auth().verifyIdToken(m[1])).uid;
  } catch (e) {
    return res.status(401).json({ error: "Invalid or expired token" });
  }
  const db = firebaseAdmin.firestore();
  const ref = db.collection("users").doc(uid);
  const { FieldValue } = firebaseAdmin.firestore;

  try {
    const out = await db.runTransaction(
      async (t) => {
        const snap = await t.get(ref);
        if (!snap.exists) {
          throw Object.assign(new Error("User document not found"), { http: 404 });
        }
        const d = snap.data() || {};
        const nowClaim = new Date();
        if (isPremiumSubscriptionExpired(d, nowClaim)) {
          t.update(ref, PREMIUM_SUBSCRIPTION_DEMOTE_FIELDS);
          return { __premiumExpired: true };
        }
        if (!readEffectivePremiumUser(d, nowClaim)) {
          throw Object.assign(new Error("Not premium"), { http: 403 });
        }

        const monthKey = utcDayKey(nowClaim).slice(0, 7);

        const lastMonthlyBonusTs = d.lastMonthlyBonus;
        const lastMonthlyBonusAtTs = d.last_monthly_bonus_at;
        const lastRaw = lastMonthlyBonusTs || lastMonthlyBonusAtTs;
        let lastMonthKey = "";
        if (lastRaw && typeof lastRaw.toDate === "function") {
          lastMonthKey = utcDayKey(lastRaw.toDate()).slice(0, 7);
        }
        if (lastMonthKey === monthKey) {
          return { ok: true, granted: false, reason: "already_claimed_this_month" };
        }

        let paid = Number(d.paidCredits ?? 0);
        let reward = Number(d.rewardCredits ?? 0);
        if (d.paidCredits === undefined && d.credits != null) {
          paid = Number(d.credits);
          reward = 0;
        }
        const expTs = d.rewardCreditsExpiresAt;
        if (reward > 0 && expTs && expTs.toDate && expTs.toDate() < nowClaim) {
          paid += reward;
          reward = 0;
        }
        paid += PREMIUM_MONTHLY_BONUS_CREDITS;
        const total = paid + reward;
        t.update(ref, {
          paidCredits: paid,
          rewardCredits: reward,
          rewardCreditsExpiresAt: reward > 0 ? expTs : null,
          credits: total,
          lastMonthlyBonus: FieldValue.serverTimestamp(),
          last_monthly_bonus_at: FieldValue.serverTimestamp(),
        });
        return {
          ok: true,
          granted: true,
          creditsAdded: PREMIUM_MONTHLY_BONUS_CREDITS,
          newBalance: total,
        };
      },
      { maxAttempts: 20 },
    );
    if (out && out.__premiumExpired) {
      return res.status(403).json({ error: "Premium subscription expired" });
    }
    return res.status(200).json(out);
  } catch (e) {
    const code = e.http || 500;
    if (code === 403) {
      return res.status(403).json({ error: String(e.message || e) });
    }
    if (code === 404) {
      return res.status(404).json({ error: String(e.message || e) });
    }
    console.error("claim-premium-monthly-bonus:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }
});

const BROWSE_NUMBER_PRICE = Number(process.env.BROWSE_NUMBER_PRICE || 150);

/**
 * POST /purchase-browse-number — Firebase Bearer; body `{ "phoneNumber": "+1…", "price": <int> }`.
 * Replaces client-side Firestore credit deduction + Twilio purchase (must match [BROWSE_NUMBER_PRICE]).
 * **Route:** POST `/purchase-browse-number` only. Premium number claim uses POST `/purchase-number`.
 */
async function handlePurchaseBrowseNumber(req, res) {
  if (!firebaseAdmin) {
    return res.status(503).json({ error: "Firebase Admin not configured" });
  }
  const auth = req.headers.authorization || "";
  const m = /^Bearer\s+(.+)$/i.exec(auth);
  if (!m) {
    return res.status(401).json({ error: "Missing Authorization: Bearer <Firebase ID token>" });
  }
  let uid;
  try {
    uid = (await firebaseAdmin.auth().verifyIdToken(m[1])).uid;
  } catch (e) {
    console.error("verifyIdToken (purchase-browse-number):", e.message);
    return res.status(401).json({ error: "Invalid or expired token" });
  }
  const priceReq = Number(req.body && req.body.price);
  if (!Number.isFinite(priceReq) || priceReq !== BROWSE_NUMBER_PRICE) {
    return res.status(400).json({ error: "Invalid or mismatched price", expected: BROWSE_NUMBER_PRICE });
  }
  let phonePick;
  try {
    phonePick = normalizeUsE164OrThrow(req.body && req.body.phoneNumber);
  } catch (e) {
    return res.status(e.http || 400).json({ error: String(e.message || e) });
  }

  const db = firebaseAdmin.firestore();
  const ref = db.collection("users").doc(uid);
  const snap = await ref.get();
  if (!snap.exists) {
    return res.status(404).json({ error: "User document not found" });
  }
  const d = snap.data() || {};
  const usable = usableCreditsFromUserDoc(d);
  if (usable < BROWSE_NUMBER_PRICE) {
    return res.status(402).json({
      error: "Insufficient credits",
      requiredCredits: BROWSE_NUMBER_PRICE,
      usableCredits: usable,
    });
  }

  const nowBrowse = new Date();
  if (countTwilioLines(d) >= maxTwilioLinesFor(d, nowBrowse)) {
    return res.status(409).json({
      error: "Number limit reached",
      message: readEffectivePremiumUser(d, nowBrowse)
        ? "Maximum phone lines for your account."
        : "Free accounts can have one phone line.",
      max: maxTwilioLinesFor(d, nowBrowse),
    });
  }

  let incoming;
  try {
    incoming = await purchaseIncomingUsLocal(uid, phonePick);
  } catch (e) {
    console.error("purchase-browse-number Twilio:", e);
    if (isTwilioNumberUnavailableError(e)) {
      return res.status(409).json({
        error: "NUMBER_UNAVAILABLE",
        message: "Oops! This number was just taken. Please pick another one.",
      });
    }
    const status = Number(e.status);
    const http =
      e.http != null
        ? Number(e.http)
        : Number.isFinite(status) && status >= 400 && status < 600
          ? status
          : 502;
    return res.status(http).json({ error: String(e.message || e) });
  }

  const e164 = String(incoming.phoneNumber || "").trim();
  if (!e164) {
    return res.status(500).json({ error: "Twilio returned empty phone number" });
  }

  const { FieldValue, Timestamp } = firebaseAdmin.firestore;
  const now = new Date();
  let freshSnap;
  try {
    freshSnap = await ref.get();
  } catch (e) {
    console.error("purchase-browse-number re-get:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }
  const d2 = freshSnap.exists ? freshSnap.data() || {} : {};
  let paid = Number(d2.paidCredits ?? 0);
  let reward = Number(d2.rewardCredits ?? 0);
  const expTs = d2.rewardCreditsExpiresAt;
  if (reward > 0 && expTs && expTs.toDate && expTs.toDate() < now) {
    paid += reward;
    reward = 0;
  }
  if (d2.paidCredits === undefined && d2.credits != null) {
    paid = Number(d2.credits);
    reward = 0;
  }
  const deduct = BROWSE_NUMBER_PRICE;
  const usable2 = paid + reward;
  if (usable2 < deduct) {
    console.error("purchase-browse-number post-Twilio balance shortfall", uid, usable2, deduct);
    return res.status(409).json({
      error: "Balance changed during purchase — contact support if charged.",
      twilioIncomingPhoneSid: incoming.sid,
      phoneNumber: e164,
    });
  }
  let left = deduct;
  const takeReward = left < reward ? left : reward;
  reward -= takeReward;
  left -= takeReward;
  paid -= left;
  let rewardExpOut = null;
  if (reward > 0) {
    rewardExpOut = expTs && expTs.toDate && expTs.toDate() >= now ? expTs : null;
  }
  const totalOut = paid + reward;
  const browseExp = Timestamp.fromDate(new Date(now.getTime() + FREE_TIER_NUMBER_LEASE_MS));

  try {
    await ref.update({
      assigned_number: e164,
      phoneNumber: e164,
      virtual_number: e164,
      allocatedNumber: e164,
      number: e164,
      twilioIncomingPhoneSid: incoming.sid,
      twilioPhoneNumberSid: incoming.sid,
      twilioNumberAssignedAt: FieldValue.serverTimestamp(),
      numberStatus: "active",
      number_status: "active",
      number_expiry_date: browseExp,
      expiry_date: browseExp,
      numberExpiry: browseExp,
      number_plan_type: "browse_credits",
      number_tier: "vip",
      number_renew_ad_progress: 0,
      paidCredits: paid,
      rewardCredits: reward,
      rewardCreditsExpiresAt: rewardExpOut,
      credits: totalOut,
    });
  } catch (e) {
    console.error("purchase-browse-number Firestore update:", e);
    return res.status(500).json({
      error: String(e.message || e),
      warning:
        "Twilio number was purchased but profile update failed — check Twilio Console and Firestore manually.",
      twilioIncomingPhoneSid: incoming.sid,
      phoneNumber: e164,
    });
  }

  return res.status(200).json({
    ok: true,
    assigned_number: e164,
    twilioIncomingPhoneSid: incoming.sid,
    creditsDeducted: deduct,
    newBalance: totalOut,
    number_expiry_date: browseExp.toDate().toISOString(),
    expiry_date: browseExp.toDate().toISOString(),
    numberExpiry: browseExp.toDate().toISOString(),
  });
}

app.post("/purchase-browse-number", handlePurchaseBrowseNumber);

/** Constant-time compare for [ADMIN_SECRET_KEY] (mitigate timing leaks on guessable lengths). */
function adminSecretMatches(provided, expected) {
  const a = Buffer.from(String(provided ?? ""), "utf8");
  const b = Buffer.from(String(expected ?? ""), "utf8");
  if (a.length !== b.length) {
    return false;
  }
  return crypto.timingSafeEqual(a, b);
}

const ADMIN_UPGRADE_BONUS_CREDITS = Number(process.env.ADMIN_UPGRADE_BONUS_CREDITS || 1000);

/**
 * POST /admin/upgrade-user — Admin-only: set `isPremium: true`, grant bonus credits, align tier fields.
 * **Auth:** `X-Admin-Secret: <ADMIN_SECRET_KEY>` or `Authorization: Bearer <ADMIN_SECRET_KEY>`
 * (or JSON body `secret` for quick curl — prefer headers in production).
 * **Body:** `{ "targetUid": "<Firebase Auth uid>" }`
 * Later: call from Razorpay/Stripe webhook with the same secret (or move to signed JWT).
 */
app.post("/admin/upgrade-user", async (req, res) => {
  if (!firebaseAdmin) {
    return res.status(503).json({ error: "Firebase Admin not configured (set FIREBASE_SERVICE_ACCOUNT_JSON)" });
  }
  const envSecret = process.env.ADMIN_SECRET_KEY;
  if (!envSecret || String(envSecret).trim() === "") {
    console.error("ADMIN_SECRET_KEY is empty — refusing POST /admin/upgrade-user");
    return res.status(503).json({ error: "Admin upgrade not configured (set ADMIN_SECRET_KEY)" });
  }
  const headerSecret = req.headers["x-admin-secret"];
  const bearer =
    typeof req.headers.authorization === "string"
      ? /^Bearer\s+(.+)$/i.exec(req.headers.authorization)
      : null;
  const provided =
    (headerSecret != null && String(headerSecret)) ||
    (bearer ? bearer[1].trim() : "") ||
    (req.body && req.body.secret != null ? String(req.body.secret) : "");
  if (!provided || !adminSecretMatches(provided, envSecret)) {
    return res.status(401).json({ error: "Unauthorized" });
  }

  const targetUid = String(req.body?.targetUid ?? "").trim();
  if (!targetUid) {
    return res.status(400).json({ error: "Missing targetUid" });
  }

  const bonus = Number.isFinite(ADMIN_UPGRADE_BONUS_CREDITS) && ADMIN_UPGRADE_BONUS_CREDITS > 0
    ? Math.floor(ADMIN_UPGRADE_BONUS_CREDITS)
    : 1000;

  const db = firebaseAdmin.firestore();
  const ref = db.collection("users").doc(targetUid);

  try {
    const out = await db.runTransaction(async (t) => {
      const snap = await t.get(ref);
      if (!snap.exists) {
        throw Object.assign(new Error("User document not found"), { http: 404 });
      }
      const d = snap.data();
      let paid = Number(d.paidCredits ?? 0);
      let reward = Number(d.rewardCredits ?? 0);
      if (d.paidCredits === undefined && d.credits != null) {
        paid = Number(d.credits);
        reward = 0;
      }
      const now = new Date();
      const expTs = d.rewardCreditsExpiresAt;
      if (reward > 0 && expTs && typeof expTs.toDate === "function" && expTs.toDate() < now) {
        paid += reward;
        reward = 0;
      }
      paid += bonus;
      const total = paid + reward;
      t.update(ref, {
        isPremium: true,
        subscription_tier: "premium",
        subscriptionTier: "premium",
        paidCredits: paid,
        credits: total,
        premiumWelcomeBonusGranted: true,
      });
      return { ok: true, targetUid, creditsAdded: bonus, newBalance: total, isPremium: true };
    });
    return res.status(200).json(out);
  } catch (e) {
    const code = e.http || 500;
    if (code === 404) {
      return res.status(404).json({ error: String(e.message || e) });
    }
    console.error("POST /admin/upgrade-user:", e);
    return res.status(code >= 400 && code < 600 ? code : 500).json({
      error: String(e.message || e),
    });
  }
});

/** Usable balance from Firestore `users/{uid}` (aligned with POST /grant-reward). */
function usableCreditsFromUserDoc(d) {
  let paid = Number(d.paidCredits ?? 0);
  let reward = Number(d.rewardCredits ?? 0);
  if (d.paidCredits === undefined && d.credits != null) {
    paid = Number(d.credits);
    reward = 0;
  }
  const now = new Date();
  const expTs = d.rewardCreditsExpiresAt;
  if (reward > 0 && expTs && typeof expTs.toDate === "function" && expTs.toDate() < now) {
    paid += reward;
    reward = 0;
  }
  return paid + reward;
}

/** Lifetime rewarded-ad views (`ads_watched_count`, incremented each POST /grant-reward). */
function readLifetimeAdsWatched(d) {
  const n = d.ads_watched_count;
  if (n === undefined || n === null || n === "") return 0;
  const x = Number(n);
  return Number.isFinite(x) ? x : 0;
}

/** Free US line unlock — `number_ads_progress` (default 80); migrates from lifetime ads if unset. */
const NUMBER_UNLOCK_ADS_REQUIRED = Math.max(
  1,
  Math.min(500, Number(process.env.NUMBER_UNLOCK_ADS_REQUIRED || 80)),
);
/** Free outbound SMS: bank this many rewarded ads per send (default 5). */
const OTP_ADS_REQUIRED_PER_SMS = Math.max(
  1,
  Math.min(20, Number(process.env.OTP_ADS_REQUIRED_PER_SMS || 5)),
);

function readNumberAdsProgress(d) {
  if (!d || typeof d !== "object") return 0;
  const raw = d.number_ads_progress;
  if (raw !== undefined && raw !== null && raw !== "") {
    const x = Number(raw);
    if (Number.isFinite(x)) return Math.max(0, Math.min(NUMBER_UNLOCK_ADS_REQUIRED, x));
  }
  return Math.min(NUMBER_UNLOCK_ADS_REQUIRED, readLifetimeAdsWatched(d));
}

function readOtpAdsProgress(d) {
  if (!d || typeof d !== "object") return 0;
  const x = Number(d.otp_ads_progress ?? 0);
  if (!Number.isFinite(x)) return 0;
  return Math.max(0, Math.min(OTP_ADS_REQUIRED_PER_SMS, x));
}

const ASSIGN_NUMBER_MIN_CREDITS = Number(process.env.ASSIGN_NUMBER_MIN_CREDITS || 100);
const ASSIGN_NUMBER_MIN_ADS_WATCHED = Number(
  process.env.ASSIGN_NUMBER_MIN_ADS_WATCHED || NUMBER_UNLOCK_ADS_REQUIRED,
);
const ASSIGN_NUMBER_AREA_CODE = process.env.ASSIGN_NUMBER_AREA_CODE
  ? Number.parseInt(String(process.env.ASSIGN_NUMBER_AREA_CODE).trim(), 10)
  : null;

/** Credits charged for leasing a Twilio number by plan (premium users: cost 0). */
const PLAN_ASSIGN_CREDITS = {
  daily: Number(process.env.PLAN_DAILY_CREDITS || 30),
  weekly: Number(process.env.PLAN_WEEKLY_CREDITS || 150),
  monthly: Number(process.env.PLAN_MONTHLY_CREDITS || 400),
  yearly: Number(process.env.PLAN_YEARLY_CREDITS || 3000),
};

/** Lease duration from assignment time (ms). */
const PLAN_ASSIGN_MS = {
  daily: Number(process.env.PLAN_DAILY_MS || 86400000),
  weekly: Number(process.env.PLAN_WEEKLY_MS || 604800000),
  monthly: Number(process.env.PLAN_MONTHLY_MS || 2592000000),
  yearly: Number(process.env.PLAN_YEARLY_MS || 31536000000),
};

/** Free non‑Pro Twilio line lease wall‑clock (default 24h). */
const FREE_TIER_NUMBER_LEASE_MS = Number(process.env.FREE_TIER_NUMBER_LEASE_MS || 86400000);
/** Rewarded ads banked toward POST `/renew-number` (mode `ads`). */
const NUMBER_RENEW_ADS_REQUIRED = Math.max(
  1,
  Math.min(100, Number(process.env.NUMBER_RENEW_ADS_REQUIRED || 5)),
);
const NUMBER_RENEW_CREDITS = Number(process.env.NUMBER_RENEW_CREDITS || 100);
const SMS_OUTBOUND_CREDIT_COST = Math.max(0, Number(process.env.SMS_OUTBOUND_CREDIT_COST || 3));
const MAX_TWILIO_LINES_FREE = Math.max(1, Number(process.env.MAX_TWILIO_LINES_FREE || 1));
const MAX_TWILIO_LINES_PREMIUM = Math.max(1, Number(process.env.MAX_TWILIO_LINES_PREMIUM || 2));

/** After Twilio release, block re-provisioning this E.164 until this many ms (default 24h). */
const NUMBER_REUSE_COOLDOWN_MS = Number(process.env.NUMBER_REUSE_COOLDOWN_MS || 86400000);
/** Pro subscription lines: extra time after `numberExpiry` before janitor releases (default 6h). */
const PREMIUM_SUBSCRIPTION_GRACE_MS = Number(process.env.PREMIUM_SUBSCRIPTION_GRACE_MS || 21600000);
/** Max POST `/renew-number` successes per UTC calendar day per user (default 2). */
const MAX_RENEWALS_PER_DAY = Math.max(0, Math.min(50, Number(process.env.MAX_RENEWALS_PER_DAY || 2)));

const RELEASED_NUMBERS_COLLECTION = "released_numbers";

/**
 * @param {string} raw
 * @returns {"daily"|"weekly"|"monthly"|"yearly"|null}
 */
function normalizePlanType(raw) {
  const s = String(raw ?? "")
    .trim()
    .toLowerCase();
  if (
    [
      "daily",
      "weekly",
      "monthly",
      "yearly",
      "starter_credits",
      "credit_pack_small",
      "credit_pack_medium",
      "credit_pack_large",
    ].includes(s)
  ) {
    return s;
  }
  return null;
}

function countTwilioLines(d) {
  if (!d) return 0;
  let n = 0;
  const p = String(d.assigned_number ?? d.phoneNumber ?? "").trim();
  if (p && p.toLowerCase() !== "none") n += 1;
  const a = String(d.alt_assigned_number ?? "").trim();
  if (a && a.toLowerCase() !== "none") n += 1;
  return n;
}

function maxTwilioLinesFor(d, nowDate = new Date()) {
  return readEffectivePremiumUser(d, nowDate) ? MAX_TWILIO_LINES_PREMIUM : MAX_TWILIO_LINES_FREE;
}

/** Outbound SMS credit deduction (reward balance first). */
async function deductCreditsForSms(uid, cost) {
  if (!firebaseAdmin || !cost || cost <= 0) return { newBalance: null };
  const db = firebaseAdmin.firestore();
  const ref = db.collection("users").doc(uid);
  return db.runTransaction(async (t) => {
    const snap = await t.get(ref);
    const d = snap.exists ? snap.data() || {} : {};
    const usable = usableCreditsFromUserDoc(d);
    if (usable < cost) {
      throw Object.assign(new Error("Insufficient credits for outbound SMS"), {
        http: 402,
        usableCredits: usable,
        requiredCredits: cost,
      });
    }
    let paid = Number(d.paidCredits ?? 0);
    let reward = Number(d.rewardCredits ?? 0);
    if (d.paidCredits === undefined && d.credits != null) {
      paid = Number(d.credits);
      reward = 0;
    }
    const now = new Date();
    const expTs = d.rewardCreditsExpiresAt;
    if (reward > 0 && expTs && expTs.toDate && expTs.toDate() < now) {
      paid += reward;
      reward = 0;
    }
    let left = cost;
    const takeReward = left < reward ? left : reward;
    reward -= takeReward;
    left -= takeReward;
    paid -= left;
    let rewardExpOut = null;
    if (reward > 0) {
      rewardExpOut = expTs && expTs.toDate && expTs.toDate() >= now ? expTs : null;
    }
    const totalOut = paid + reward;
    t.update(ref, {
      paidCredits: paid,
      rewardCredits: reward,
      rewardCreditsExpiresAt: rewardExpOut,
      credits: totalOut,
    });
    return { newBalance: totalOut };
  });
}

async function refundSmsCredits(uid, cost) {
  if (!firebaseAdmin || !cost || cost <= 0) return;
  const { FieldValue } = firebaseAdmin.firestore;
  const ref = firebaseAdmin.firestore().collection("users").doc(uid);
  await ref.update({
    paidCredits: FieldValue.increment(cost),
    credits: FieldValue.increment(cost),
  });
}

/** Restore free-tier OTP ad bank after Twilio failure (see POST /send-sms). */
async function refundOtpAdsProgress(uid, delta) {
  if (!firebaseAdmin || !delta || delta <= 0) return;
  const { FieldValue } = firebaseAdmin.firestore;
  const ref = firebaseAdmin.firestore().collection("users").doc(uid);
  await ref.update({
    otp_ads_progress: FieldValue.increment(delta),
  });
}

/** US E.164 (+1 + 10 digits, NPA 2–9). */
function normalizeUsE164OrThrow(phone) {
  const s = String(phone ?? "")
    .trim()
    .replace(/\s/g, "");
  if (!/^\+1[2-9]\d{9}$/.test(s)) {
    const err = new Error("phoneNumber must be US E.164 (e.g. +15551234567)");
    err.http = 400;
    throw err;
  }
  return s;
}

/**
 * Twilio `incomingPhoneNumbers.create` can fail if the number was just bought by someone else.
 * RestException uses numeric `code` (e.g. 21422); message often contains "not available".
 */
function isTwilioNumberUnavailableError(e) {
  if (!e || typeof e !== "object") return false;
  const n = Number(e.code);
  // 21422: requested phone number is not available (inventory / race).
  if (n === 21422) return true;
  const msg = String(e.message || e).toLowerCase();
  return /not available|no longer available|already been purchased|already provisioned|another account|inventory/.test(
    msg,
  );
}

function e164ToReuseDocId(e164) {
  return String(e164 ?? "")
    .replace(/\D/g, "");
}

/**
 * @returns {Promise<number|null>} millis when reusable, or null if not in cooldown
 */
async function getReuseCooldownUntilMs(e164) {
  if (!firebaseAdmin) return null;
  let normalized;
  try {
    normalized = normalizeUsE164OrThrow(e164);
  } catch {
    return null;
  }
  const id = e164ToReuseDocId(normalized);
  if (!id) return null;
  const snap = await firebaseAdmin.firestore().collection(RELEASED_NUMBERS_COLLECTION).doc(id).get();
  if (!snap.exists) return null;
  const ra = snap.data()?.reusable_after;
  if (ra && typeof ra.toMillis === "function") return ra.toMillis();
  return null;
}

async function assertPhoneReusableOrThrow(e164) {
  const until = await getReuseCooldownUntilMs(e164);
  if (until != null && until > Date.now()) {
    const err = new Error("Number is cooling down before reuse — pick another.");
    err.http = 409;
    err.code = "NUMBER_IN_REUSE_COOLDOWN";
    err.reusableAfter = new Date(until).toISOString();
    throw err;
  }
}

async function recordReleasedNumber(e164) {
  if (!firebaseAdmin) return;
  let normalized;
  try {
    normalized = normalizeUsE164OrThrow(e164);
  } catch (e) {
    console.warn("[released_numbers] skip invalid e164:", e.message || e);
    return;
  }
  const { Timestamp } = firebaseAdmin.firestore;
  const id = e164ToReuseDocId(normalized);
  const after = Timestamp.fromMillis(Date.now() + NUMBER_REUSE_COOLDOWN_MS);
  await firebaseAdmin
    .firestore()
    .collection(RELEASED_NUMBERS_COLLECTION)
    .doc(id)
    .set(
      {
        phoneNumber: normalized,
        reusable_after: after,
        released_at: Timestamp.now(),
      },
      { merge: true },
    );
}

async function clearReuseCooldownRecord(e164) {
  if (!firebaseAdmin) return;
  try {
    const normalized = normalizeUsE164OrThrow(e164);
    const id = e164ToReuseDocId(normalized);
    await firebaseAdmin.firestore().collection(RELEASED_NUMBERS_COLLECTION).doc(id).delete();
  } catch (_) {
    /* ignore */
  }
}

/** @param {string[]} e164Candidates */
async function filterPhoneNumbersPastReuseCooldown(e164Candidates) {
  if (!firebaseAdmin || !e164Candidates || !e164Candidates.length) return e164Candidates || [];
  const db = firebaseAdmin.firestore();
  const refs = [];
  const normalizedList = [];
  for (const raw of e164Candidates) {
    try {
      const n = normalizeUsE164OrThrow(String(raw).trim());
      refs.push(db.collection(RELEASED_NUMBERS_COLLECTION).doc(e164ToReuseDocId(n)));
      normalizedList.push(n);
    } catch {
      /* skip */
    }
  }
  if (!refs.length) return e164Candidates;
  const snaps = await db.getAll(...refs);
  const blocked = new Set();
  const now = Date.now();
  snaps.forEach((sn) => {
    if (!sn.exists) return;
    const ra = sn.data()?.reusable_after;
    if (ra && ra.toMillis && ra.toMillis() > now) blocked.add(sn.id);
  });
  return normalizedList.filter((n) => !blocked.has(e164ToReuseDocId(n)));
}

/**
 * Purchase a specific US local number from Twilio (must still be available — use GET /available-numbers).
 * Voice URL → /voice-inbound-number; SMS → /sms-webhook.
 */
async function purchaseIncomingUsLocal(uid, phoneNumberE164) {
  await assertPhoneReusableOrThrow(phoneNumberE164);
  const normalized = normalizeUsE164OrThrow(phoneNumberE164);
  const incoming = await twilioClient.incomingPhoneNumbers.create({
    phoneNumber: normalized,
    friendlyName: `TalkFree ${String(uid).slice(0, 12)}`,
    smsUrl: `${publicBase}/sms-webhook`,
    smsMethod: "POST",
    voiceUrl: `${publicBase}/voice-inbound-number`,
    voiceMethod: "POST",
  });
  await clearReuseCooldownRecord(normalized);
  return incoming;
}

/**
 * Search US local inventory. Used by GET /available-numbers.
 * `smsEnabled` + `mmsEnabled` → SMS/OTP-capable; `voiceEnabled` → call verification.
 * (WhatsApp Business registration is separate, but these flags keep numbers usable for SMS/voice OTP.)
 * @param {{ areaCode?: string }} opts
 */
async function searchAvailableUsLocalVoiceSmsMms(opts = {}) {
  const params = {
    limit: 10,
    voiceEnabled: true,
    smsEnabled: true,
    mmsEnabled: true,
  };
  const ac = opts.areaCode != null ? String(opts.areaCode).trim() : "";
  if (/^\d{3}$/.test(ac)) {
    params.areaCode = ac;
  } else if (Number.isFinite(ASSIGN_NUMBER_AREA_CODE)) {
    params.areaCode = ASSIGN_NUMBER_AREA_CODE;
  }
  return twilioClient.availablePhoneNumbers("US").local.list(params);
}

/**
 * Premium-only search: Local or Mobile inventory for an ISO country (default US).
 * @param {{ country: string, numberType: 'local'|'mobile', areaCode?: string }} opts
 */
async function searchAvailableNumbersPremium(opts = {}) {
  const country = String(opts.country || "US")
    .trim()
    .toUpperCase();
  const numberType = String(opts.numberType || "local")
    .trim()
    .toLowerCase();
  const params = {
    limit: 20,
    voiceEnabled: true,
    smsEnabled: true,
  };
  const ac = opts.areaCode != null ? String(opts.areaCode).trim() : "";
  if (/^\d{3}$/.test(ac)) {
    params.areaCode = ac;
  }

  const api = twilioClient.availablePhoneNumbers(country);
  if (numberType === "mobile") {
    return api.mobile.list(params);
  }
  if (country === "US") {
    params.mmsEnabled = true;
    if (!params.areaCode && Number.isFinite(ASSIGN_NUMBER_AREA_CODE)) {
      params.areaCode = ASSIGN_NUMBER_AREA_CODE;
    }
  }
  return api.local.list(params);
}

/** Map Twilio available-number instance to API JSON (phoneNumber, isoCountry, capabilities). */
function mapTwilioAvailableNumber(n, isoCountry) {
  const c = n.capabilities || {};
  return {
    phoneNumber: n.phoneNumber,
    isoCountry,
    capabilities: {
      voice: !!c.voice,
      sms: !!(c.SMS || c.sms),
      mms: !!(c.MMS || c.mms),
    },
  };
}

/** Inbound PSTN call to a purchased TalkFree number — simple placeholder TwiML. */
app.all("/voice-inbound-number", (req, res) => {
  const vr = new twilio.twiml.VoiceResponse();
  vr.say(
    { voice: "alice" },
    "Thanks for calling. This TalkFree number does not accept voice mail. Please reach the user in the TalkFree app.",
  );
  vr.hangup();
  res.type("text/xml");
  res.send(vr.toString());
});

/**
 * Pick which `users/{uid}` owns this Twilio number if multiple docs match (recycle edge case).
 * Prefer latest `twilioNumberAssignedAt`, then `created_at` / `createdAt`, then uid lexicographic.
 */
function pickUidForAssignedNumber(docs) {
  if (!docs.length) return null;
  if (docs.length === 1) return docs[0].id;

  function docTimeMs(doc) {
    const d = doc.data() || {};
    const a = d.twilioNumberAssignedAt;
    if (a && typeof a.toMillis === "function") return a.toMillis();
    const c = d.created_at || d.createdAt;
    if (c && typeof c.toMillis === "function") return c.toMillis();
    return 0;
  }

  const ranked = docs
    .map((doc) => ({ id: doc.id, ms: docTimeMs(doc) }))
    .sort((x, y) => {
      if (y.ms !== x.ms) return y.ms - x.ms;
      return x.id.localeCompare(y.id);
    });

  if (ranked[0].ms === 0) {
    console.warn(
      `sms-webhook: ${docs.length} users share assigned_number; tie-break by uid (set twilioNumberAssignedAt on provision)`,
    );
  }
  return ranked[0].id;
}

/**
 * Twilio inbound SMS — POST to a provisioned number → `users/{uid}/messages/{autoId}`.
 * `createdAt` uses server timestamps for correct inbox ordering. Always respond 200 with empty TwiML.
 */
app.post("/sms-webhook", async (req, res) => {
  const canonicalUrl = `${publicBase}/sms-webhook`;
  const sig = req.get("X-Twilio-Signature") || "";
  if (process.env.SKIP_TWILIO_SIGNATURE !== "1" && TWILIO_AUTH_TOKEN) {
    const ok = twilio.validateRequest(TWILIO_AUTH_TOKEN, sig, canonicalUrl, req.body);
    if (!ok) {
      console.warn("/sms-webhook: invalid Twilio signature");
      return res.status(403).send("Forbidden");
    }
  }

  const To = String(req.body.To || "").trim();
  const From = String(req.body.From || "").trim();
  const Body = String(req.body.Body || "");
  const mr = new twilio.twiml.MessagingResponse();

  if (!firebaseAdmin) {
    console.warn("sms-webhook: Firebase Admin not configured — message not stored");
    res.type("text/xml");
    return res.status(200).send(mr.toString());
  }

  try {
    const db = firebaseAdmin.firestore();
    const { FieldValue } = firebaseAdmin.firestore;
    let q = await db.collection("users").where("assigned_number", "==", To).get();
    if (q.empty) {
      q = await db.collection("users").where("alt_assigned_number", "==", To).get();
    }
    if (q.empty) {
      console.warn("sms-webhook: no user with assigned_number / alt_assigned_number=", To);
    } else {
      const uid = pickUidForAssignedNumber(q.docs);
      if (uid) {
        await db
          .collection("users")
          .doc(uid)
          .collection("messages")
          .add({
            from: From,
            to: To,
            body: Body,
            direction: "inbound",
            createdAt: FieldValue.serverTimestamp(),
          });
        console.log(
          `sms-webhook: users/${uid}/messages (new doc) inbound from=${From} matches=${q.docs.length}`,
        );
      }
    }
  } catch (e) {
    console.error("sms-webhook:", e);
  }
  res.type("text/xml");
  return res.status(200).send(mr.toString());
});

/**
 * GET /available-numbers — up to 10 US local candidates (Voice + SMS + MMS).
 * Authorization: Bearer &lt;Firebase ID token&gt;. Optional: ?areaCode=415
 */
app.get("/available-numbers", async (req, res) => {
  const auth = req.headers.authorization || "";
  const m = /^Bearer\s+(.+)$/i.exec(auth);
  if (!m) {
    return res.status(401).json({ error: "Missing Authorization: Bearer <Firebase ID token>" });
  }
  if (!firebaseAdmin) {
    return res.status(503).json({ error: "Firebase Admin not configured" });
  }
  try {
    await firebaseAdmin.auth().verifyIdToken(m[1]);
  } catch (e) {
    console.error("verifyIdToken (available-numbers):", e.message);
    return res.status(401).json({ error: "Invalid or expired token" });
  }
  try {
    const areaCode = req.query.areaCode != null ? String(req.query.areaCode).trim() : "";
    const list = await searchAvailableUsLocalVoiceSmsMms(
      /^\d{3}$/.test(areaCode) ? { areaCode } : {},
    );
    const numbers = list.map((n) => ({
      phoneNumber: n.phoneNumber,
      friendlyName: n.friendlyName || null,
      locality: n.locality || null,
      region: n.region || null,
      postalCode: n.postalCode || null,
      capabilities: n.capabilities || {},
    }));
    const allowed = new Set(await filterPhoneNumbersPastReuseCooldown(numbers.map((n) => n.phoneNumber)));
    const numbersOut = numbers.filter((n) => allowed.has(n.phoneNumber));
    return res.status(200).json({
      ok: true,
      count: numbersOut.length,
      numbers: numbersOut,
      reuseCooldownHours: NUMBER_REUSE_COOLDOWN_MS / 3600000,
    });
  } catch (e) {
    console.error("GET /available-numbers:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }
});

const AVAILABLE_LOCAL_PATH_PREFIX = `/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/AvailablePhoneNumbers/`;

/**
 * Normalize Twilio `next_page_uri` (path+query) or full `https://api.twilio.com/...` URL for pagination.
 * Rejects paths outside this account’s AvailablePhoneNumbers API.
 */
function normalizeBrowseInventoryNextPage(raw) {
  const s = String(raw ?? "").trim();
  if (!s) return null;
  try {
    let pathQuery;
    if (/^https:\/\//i.test(s)) {
      const u = new URL(s);
      if (u.hostname !== "api.twilio.com") return null;
      pathQuery = u.pathname + (u.search || "");
    } else {
      const decoded = decodeURIComponent(s);
      pathQuery = decoded.startsWith("/") ? decoded : `/${decoded}`;
    }
    if (pathQuery.includes("..")) return null;
    if (!pathQuery.startsWith(AVAILABLE_LOCAL_PATH_PREFIX)) return null;
    return pathQuery;
  } catch (_) {
    return null;
  }
}

/**
 * GET /browse-available-numbers — US/CA local Twilio inventory (paginated). Server-side only; no Twilio secrets in the app.
 * **Auth:** `Authorization: Bearer <Firebase ID token>`.
 * Query: `country`=US|CA, optional `pageSize`, `areaCode`, `contains`, `inRegion`, `nextPage` (opaque path from prior response).
 */
app.get("/browse-available-numbers", async (req, res) => {
  const uid = await getUidFromBearer(req, res);
  if (!uid) return;
  const country = String(req.query.country || "US")
    .trim()
    .toUpperCase();
  if (country !== "US" && country !== "CA") {
    return res.status(400).json({ error: "country must be US or CA" });
  }
  const nextNorm = normalizeBrowseInventoryNextPage(req.query.nextPage);
  let requestUrl;
  if (nextNorm) {
    requestUrl = `https://api.twilio.com${nextNorm}`;
  } else {
    const pageSize = Math.min(1000, Math.max(1, Number(req.query.pageSize) || 100));
    const params = new URLSearchParams();
    params.set("PageSize", String(pageSize));
    const ac = String(req.query.areaCode ?? "")
      .trim()
      .replace(/\D/g, "");
    if (ac.length >= 3) {
      params.set("AreaCode", ac.substring(0, 3));
    }
    const rawContains = String(req.query.contains ?? "")
      .trim()
      .replace(/\D/g, "");
    if (rawContains.length > 0) {
      params.set(
        "Contains",
        rawContains.length > 7 ? rawContains.substring(0, 7) : rawContains,
      );
    }
    const reg = String(req.query.inRegion ?? "").trim();
    if (reg.length > 0) {
      params.set("InRegion", reg.length <= 2 ? reg.toUpperCase() : reg);
    }
    requestUrl = `https://api.twilio.com${AVAILABLE_LOCAL_PATH_PREFIX}${country}/Local.json?${params.toString()}`;
  }
  const basic = Buffer.from(`${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}`).toString("base64");
  try {
    const r = await fetch(requestUrl, {
      headers: { Authorization: `Basic ${basic}`, Accept: "application/json" },
    });
    const text = await r.text();
    if (!r.ok) {
      console.error("browse-available-numbers Twilio HTTP", r.status, text.slice(0, 500));
      return res.status(502).json({
        error: "Twilio inventory request failed",
        status: r.status,
      });
    }
    let decoded;
    try {
      decoded = JSON.parse(text);
    } catch (e) {
      return res.status(502).json({ error: "Invalid JSON from Twilio" });
    }
    const list = decoded.available_phone_numbers || [];
    const nextRaw = decoded.next_page_uri;
    let nextPage = null;
    if (nextRaw && String(nextRaw).trim()) {
      const nr = String(nextRaw).trim();
      try {
        const pq = nr.startsWith("http") ? new URL(nr).pathname + new URL(nr).search : nr;
        nextPage = pq.startsWith("/") ? pq : `/${pq}`;
      } catch (_) {
        nextPage = null;
      }
    }
    const numbersRaw = list.map((item) => ({
      phoneNumber: item.phone_number,
      locality: item.locality || null,
      region: item.region || null,
      friendlyName: item.friendly_name || null,
      postalCode: item.postal_code || null,
      country,
    }));
    const allowed = new Set(
      await filterPhoneNumbersPastReuseCooldown(numbersRaw.map((n) => n.phoneNumber).filter(Boolean)),
    );
    const numbers = numbersRaw.filter((n) => n.phoneNumber && allowed.has(n.phoneNumber));
    return res.status(200).json({
      ok: true,
      country,
      numbers,
      nextPage,
      reuseCooldownHours: NUMBER_REUSE_COOLDOWN_MS / 3600000,
    });
  } catch (e) {
    console.error("GET /browse-available-numbers:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }
});

/**
 * GET /api/twilio/available-numbers — **Pro only** (free unlock uses auto-assign after NUMBER_UNLOCK_ADS_REQUIRED ads).
 * Local or Mobile inventory by country.
 * Authorization: Bearer <Firebase ID token>.
 * Query: country=US (ISO 3166-1 alpha-2), numberType=local|mobile, optional areaCode=415
 */
app.get("/api/twilio/available-numbers", async (req, res) => {
  const auth = req.headers.authorization || "";
  const m = /^Bearer\s+(.+)$/i.exec(auth);
  if (!m) {
    return res.status(401).json({ error: "Missing Authorization: Bearer <Firebase ID token>" });
  }
  if (!firebaseAdmin) {
    return res.status(503).json({ error: "Firebase Admin not configured" });
  }
  let uid;
  try {
    uid = (await firebaseAdmin.auth().verifyIdToken(m[1])).uid;
  } catch (e) {
    console.error("verifyIdToken (api/twilio/available-numbers):", e.message);
    return res.status(401).json({ error: "Invalid or expired token" });
  }

  try {
    const snap = await firebaseAdmin.firestore().collection("users").doc(uid).get();
    const d = snap.data() || {};
    const nowAvail = new Date();
    const premium = readEffectivePremiumUser(d, nowAvail);
    if (!premium) {
      return res.status(403).json({
        error: "Premium required",
        message: `Browse inventory is included with Pro. Free accounts receive an auto-assigned US line after ${NUMBER_UNLOCK_ADS_REQUIRED} rewarded ads.`,
      });
    }
  } catch (e) {
    console.error("GET /api/twilio/available-numbers firestore:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }

  const country =
    req.query.country != null ? String(req.query.country).trim().toUpperCase() : "US";
  const numberType =
    req.query.numberType != null
      ? String(req.query.numberType).trim().toLowerCase()
      : "local";
  if (!/^[A-Z]{2}$/.test(country)) {
    return res.status(400).json({
      error: "Invalid country — use ISO 3166-1 alpha-2, e.g. US",
    });
  }
  if (numberType !== "local" && numberType !== "mobile") {
    return res.status(400).json({
      error: "Invalid numberType — use local or mobile",
    });
  }

  try {
    const areaCode = req.query.areaCode != null ? String(req.query.areaCode).trim() : "";
    const list = await searchAvailableNumbersPremium({
      country,
      numberType,
      areaCode: /^\d{3}$/.test(areaCode) ? areaCode : "",
    });
    const numbers = list.map((n) => mapTwilioAvailableNumber(n, country));
    const allowed = new Set(await filterPhoneNumbersPastReuseCooldown(numbers.map((n) => n.phoneNumber)));
    const numbersOut = numbers.filter((n) => allowed.has(n.phoneNumber));
    return res.status(200).json({
      ok: true,
      country,
      numberType,
      count: numbersOut.length,
      numbers: numbersOut,
      reuseCooldownHours: NUMBER_REUSE_COOLDOWN_MS / 3600000,
    });
  } catch (e) {
    console.error("GET /api/twilio/available-numbers twilio:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }
});

/**
 * POST /api/twilio/provision-number — premium only; purchase a specific US E.164 and update Firestore.
 * Body: `{ "phoneNumber": "+1…" }`
 * Authorization: Bearer &lt;Firebase ID token&gt;
 *
 * Buys the line via Twilio `incomingPhoneNumbers.create` (see [purchaseIncomingUsLocal]: `phoneNumber` plus SMS/Voice webhooks).
 * On Twilio failure, responds **400** with Twilio’s message in `error`.
 */
app.post("/api/twilio/provision-number", async (req, res) => {
  if (!firebaseAdmin) {
    return res.status(503).json({ error: "Firebase Admin not configured" });
  }
  const auth = req.headers.authorization || "";
  const m = /^Bearer\s+(.+)$/i.exec(auth);
  if (!m) {
    return res.status(401).json({ error: "Missing Authorization: Bearer <Firebase ID token>" });
  }
  let uid;
  try {
    uid = (await firebaseAdmin.auth().verifyIdToken(m[1])).uid;
  } catch (e) {
    console.error("verifyIdToken (api/twilio/provision-number):", e.message);
    return res.status(401).json({ error: "Invalid or expired token" });
  }

  const phoneRaw =
    req.body && req.body.phoneNumber != null
      ? String(req.body.phoneNumber).trim().replace(/\s/g, "")
      : "";
  if (!phoneRaw) {
    return res.status(400).json({ error: "Missing phoneNumber in JSON body" });
  }

  const db = firebaseAdmin.firestore();
  const ref = db.collection("users").doc(uid);
  const { FieldValue, Timestamp } = firebaseAdmin.firestore;

  let snap;
  try {
    snap = await ref.get();
  } catch (e) {
    console.error("POST /api/twilio/provision-number get user:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }
  if (!snap.exists) {
    return res.status(404).json({ error: "User document not found" });
  }

  const d = snap.data() || {};
  const nowProv = new Date();
  if (!readEffectivePremiumUser(d, nowProv)) {
    return res.status(403).json({
      error: "Premium required",
      message: "Only premium users can provision a number via this endpoint.",
    });
  }

  const primary = String(d.assigned_number ?? "").trim();
  if (primary && primary.toLowerCase() !== "none") {
    return res.status(409).json({
      error: "Already assigned",
      message: "This account already has an assigned number.",
      assigned_number: primary,
    });
  }

  const nowDate = nowProv;
  const lineExpTs = Timestamp.fromDate(premiumLineExpiryFromUserDoc(d, nowDate));

  let incoming;
  try {
    incoming = await purchaseIncomingUsLocal(uid, phoneRaw);
  } catch (e) {
    console.error("POST /api/twilio/provision-number Twilio:", e);
    return res.status(400).json({ error: String(e.message || e) });
  }

  const e164 = String(incoming.phoneNumber || "").trim();
  if (!e164) {
    return res.status(400).json({ error: "Twilio returned empty phone number" });
  }

  try {
    await ref.update({
      assigned_number: e164,
      phoneNumber: e164,
      virtual_number: e164,
      allocatedNumber: e164,
      number: e164,
      twilioIncomingPhoneSid: incoming.sid,
      twilioPhoneNumberSid: incoming.sid,
      twilioNumberAssignedAt: FieldValue.serverTimestamp(),
      number_assigned_at: FieldValue.serverTimestamp(),
      numberStatus: "active",
      number_status: "active",
      userNumber: e164,
      number_country: "US",
      number_created_at: FieldValue.serverTimestamp(),
      number_expiry_date: lineExpTs,
      expiry_date: lineExpTs,
      numberExpiry: lineExpTs,
      number_plan_type: String(d.premium_plan_type || "monthly"),
      number_tier: "premium",
      number_renew_ad_progress: 0,
    });
  } catch (e) {
    console.error("POST /api/twilio/provision-number Firestore:", e);
    return res.status(500).json({
      error: String(e.message || e),
      warning:
        "Twilio number was purchased but profile update failed — check Twilio Console and Firestore manually.",
      twilioIncomingPhoneSid: incoming.sid,
      phoneNumber: e164,
    });
  }

  return res.status(200).json({
    ok: true,
    assigned_number: e164,
    twilioIncomingPhoneSid: incoming.sid,
    number_status: "active",
  });
});

/**
 * After Twilio purchase for leased US line — deduct plan credits and write Firestore.
 * @param {Record<string, unknown>} [extraFirestore] merged into `ref.update`
 * @param {Record<string, unknown>} [extraResponse] merged into 200 JSON
 */
async function respondAfterTwilioAssignSuccess(
  res,
  {
    uid,
    ref,
    incoming,
    e164,
    planType,
    planCredits,
    premium,
    leaseMs,
    now,
    usable,
    adsLifetime,
    enoughAds,
    enoughCredits,
    /** @type {"normal"|"vip"|"premium"} */
    numberTier = "vip",
    extraFirestore = {},
    extraResponse = {},
  },
) {
  const { FieldValue, Timestamp } = firebaseAdmin.firestore;
  const expiryDate = new Date(now.getTime() + leaseMs);

  let freshSnap;
  try {
    freshSnap = await ref.get();
  } catch (e) {
    console.error("assign-number re-get:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }
  const d2 = freshSnap.exists ? freshSnap.data() || {} : {};
  let paid = Number(d2.paidCredits ?? 0);
  let reward = Number(d2.rewardCredits ?? 0);
  const rewardExpTs = d2.rewardCreditsExpiresAt;
  if (reward > 0 && rewardExpTs && rewardExpTs.toDate && rewardExpTs.toDate() < now) {
    paid += reward;
    reward = 0;
  }
  if (d2.paidCredits === undefined && d2.credits != null) {
    paid = Number(d2.credits);
    reward = 0;
  }
  let deduct = planCredits;
  const usable2 = paid + reward;
  if (usable2 < deduct) {
    console.error("assign-number post-Twilio balance shortfall", uid, usable2, deduct);
    deduct = usable2;
  }
  let left = deduct;
  const takeReward = left < reward ? left : reward;
  reward -= takeReward;
  left -= takeReward;
  paid -= left;
  let rewardExpOut = null;
  if (reward > 0) {
    rewardExpOut =
      rewardExpTs && rewardExpTs.toDate && rewardExpTs.toDate() >= now ? rewardExpTs : null;
  }
  const totalOut = paid + reward;

  const expTs = Timestamp.fromDate(expiryDate);
  const patch = {
    assigned_number: e164,
    phoneNumber: e164,
    virtual_number: e164,
    allocatedNumber: e164,
    number: e164,
    twilioIncomingPhoneSid: incoming.sid,
    twilioPhoneNumberSid: incoming.sid,
    twilioNumberAssignedAt: FieldValue.serverTimestamp(),
    numberStatus: "active",
    number_status: "active",
    number_expiry_date: expTs,
    expiry_date: expTs,
    numberExpiry: expTs,
    number_plan_type: planType,
    number_tier: numberTier,
    paidCredits: paid,
    rewardCredits: reward,
    rewardCreditsExpiresAt: rewardExpOut,
    credits: totalOut,
    ...extraFirestore,
  };

  try {
    await ref.update(patch);
  } catch (e) {
    console.error("assign-number Firestore update:", e);
    return res.status(500).json({
      error: String(e.message || e),
      warning:
        "Twilio number was purchased but profile update failed — check Twilio Console and Firestore manually.",
      twilioIncomingPhoneSid: incoming.sid,
      phoneNumber: e164,
    });
  }

  try {
    const db = firebaseAdmin.firestore();
    const { FieldValue } = firebaseAdmin.firestore;
    const numCost = Number.isFinite(EST_NUMBER_PROVISION_COST_INR)
      ? EST_NUMBER_PROVISION_COST_INR
      : 0;
    await db
      .collection("user_stats")
      .doc(uid)
      .set(
        {
          total_number_cost: FieldValue.increment(numCost),
          total_cost_estimated: FieldValue.increment(numCost),
          stats_updated_at: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
  } catch (e) {
    console.warn("user_stats (assign-number):", e.message || e);
  }

  return res.status(200).json({
    ok: true,
    assigned_number: e164,
    twilioIncomingPhoneSid: incoming.sid,
    planType,
    number_tier: numberTier,
    creditsDeducted: deduct,
    number_expiry_date: expiryDate.toISOString(),
    expiry_date: expiryDate.toISOString(),
    numberExpiry: expiryDate.toISOString(),
    newBalance: totalOut,
    usableCredits: usable,
    adsWatchedLifetime: adsLifetime,
    viaCredits: enoughCredits,
    viaAds: enoughAds,
    viaPremium: premium,
    ...extraResponse,
  });
}

/**
 * POST /assign-free-number — **free tier only**; auto-picks first US local from Twilio inventory.
 * Eligible if `number_ads_progress` ≥ NUMBER_UNLOCK_ADS_REQUIRED (default 80). No call-credit spend.
 * Body: `{ "planType": "monthly" }` (optional).
 */
app.post("/assign-free-number", async (req, res) => {
  if (!firebaseAdmin) {
    return res.status(503).json({
      error: "Assign number not configured (set FIREBASE_SERVICE_ACCOUNT_JSON on the server)",
    });
  }
  const auth = req.headers.authorization || "";
  const m = /^Bearer\s+(.+)$/i.exec(auth);
  if (!m) {
    return res.status(401).json({ error: "Missing Authorization: Bearer <Firebase ID token>" });
  }
  let uid;
  try {
    uid = (await firebaseAdmin.auth().verifyIdToken(m[1])).uid;
  } catch (e) {
    console.error("verifyIdToken (assign-free-number):", e.message);
    return res.status(401).json({ error: "Invalid or expired token" });
  }

  const db = firebaseAdmin.firestore();
  const ref = db.collection("users").doc(uid);
  let snap;
  try {
    snap = await ref.get();
  } catch (e) {
    console.error("assign-free-number get:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }
  if (!snap.exists) {
    return res.status(404).json({ error: "User document not found" });
  }
  const d = snap.data() || {};
  const nowFree = new Date();
  const existingAssigned = String(d.assigned_number ?? "").trim();
  if (existingAssigned && existingAssigned.toLowerCase() !== "none") {
    const ne = readNumberExpiryDate(d);
    return res.status(200).json({
      ok: true,
      alreadyAssigned: true,
      assigned_number: existingAssigned,
      twilioIncomingPhoneSid: d.twilioIncomingPhoneSid || d.twilioPhoneNumberSid || null,
      number_expiry_date: ne ? ne.toISOString() : null,
      expiry_date: ne ? ne.toISOString() : null,
      number_plan_type: d.number_plan_type ?? null,
    });
  }

  if (readEffectivePremiumUser(d, nowFree)) {
    return res.status(403).json({
      error: "Premium should use POST /purchase-number",
      message: "Choose your number from the app, then purchase the selected E.164.",
    });
  }

  const planType = normalizePlanType(req.body && req.body.planType);
  if (!planType) {
    return res.status(400).json({
      error: "Missing or invalid planType",
      expected: ["daily", "weekly", "monthly", "yearly"],
    });
  }

  const adsLifetime = readLifetimeAdsWatched(d);
  const numberAds = readNumberAdsProgress(d);
  const enoughAds = numberAds >= NUMBER_UNLOCK_ADS_REQUIRED;
  if (!enoughAds) {
    return res.status(403).json({
      error: "Not eligible for free auto-assign",
      detail: `Watch ${NUMBER_UNLOCK_ADS_REQUIRED} rewarded ads to unlock a free US line (separate from call credits).`,
      adsWatchedLifetime: adsLifetime,
      numberAdsProgress: numberAds,
      minAdsWatched: NUMBER_UNLOCK_ADS_REQUIRED,
    });
  }

  if (countTwilioLines(d) >= maxTwilioLinesFor(d, nowFree)) {
    return res.status(409).json({
      error: "Number limit reached",
      message: readEffectivePremiumUser(d, nowFree)
        ? "Maximum phone lines for your account."
        : "Free accounts can have one phone line.",
      max: maxTwilioLinesFor(d, nowFree),
    });
  }

  const planCredits = 0;

  const leaseMs = FREE_TIER_NUMBER_LEASE_MS;
  if (!Number.isFinite(leaseMs) || leaseMs <= 0) {
    return res.status(500).json({ error: "Plan duration configuration invalid" });
  }

  let list;
  try {
    list = await searchAvailableUsLocalVoiceSmsMms({});
  } catch (e) {
    console.error("assign-free-number Twilio search:", e);
    return res.status(503).json({ error: "No inventory search available", detail: String(e.message || e) });
  }
  if (!list || !list.length) {
    return res.status(503).json({ error: "No US numbers available — try again later." });
  }
  const candidates = list.map((x) => String(x.phoneNumber || "").trim()).filter(Boolean);
  const afterCooldown = await filterPhoneNumbersPastReuseCooldown(candidates);
  const tryList = afterCooldown.length ? afterCooldown : [];
  if (!tryList.length) {
    return res.status(503).json({
      error: "No numbers past reuse cooldown — try again later.",
      reuseCooldownHours: NUMBER_REUSE_COOLDOWN_MS / 3600000,
    });
  }

  let incoming;
  let lastErr;
  for (const phonePick of tryList) {
    try {
      incoming = await purchaseIncomingUsLocal(uid, phonePick);
      break;
    } catch (e) {
      lastErr = e;
      console.error("assign-free-number Twilio purchase try:", phonePick, e.message || e);
      if (isTwilioNumberUnavailableError(e) || (e && e.code === "NUMBER_IN_REUSE_COOLDOWN")) {
        continue;
      }
      const status = Number(e.status);
      const http =
        e.http != null
          ? Number(e.http)
          : Number.isFinite(status) && status >= 400 && status < 600
            ? status
            : 502;
      return res.status(http).json({ error: String(e.message || e) });
    }
  }
  if (!incoming) {
    return res.status(409).json({
      error: "NUMBER_UNAVAILABLE",
      code: "NUMBER_UNAVAILABLE",
      message: lastErr ? String(lastErr.message || lastErr) : "No number could be claimed — try again.",
    });
  }

  const e164 = String(incoming.phoneNumber || "").trim();
  if (!e164) {
    return res.status(500).json({ error: "Twilio returned empty phone number" });
  }

  const { FieldValue } = firebaseAdmin.firestore;
  const now = new Date();
  const enoughCredits = false;
  return respondAfterTwilioAssignSuccess(res, {
    uid,
    ref,
    incoming,
    e164,
    planType,
    planCredits,
    premium: false,
    leaseMs,
    now,
    usable,
    adsLifetime,
    enoughAds,
    enoughCredits,
    numberTier: "normal",
    extraFirestore: {
      userNumber: e164,
      number_country: "US",
      number_created_at: FieldValue.serverTimestamp(),
    },
    extraResponse: { assignMode: "free_auto", number_tier: "normal" },
  });
});

/**
 * POST /purchase-number — premium; purchase selected E.164 (alias of /api/twilio/provision-number).
 * Body: `{ "phoneNumber": "+1…" }`
 */
app.post("/purchase-number", async (req, res) => {
  if (!firebaseAdmin) {
    return res.status(503).json({ error: "Firebase Admin not configured" });
  }
  const auth = req.headers.authorization || "";
  const mm = /^Bearer\s+(.+)$/i.exec(auth);
  if (!mm) {
    return res.status(401).json({ error: "Missing Authorization: Bearer <Firebase ID token>" });
  }
  let uid;
  try {
    uid = (await firebaseAdmin.auth().verifyIdToken(mm[1])).uid;
  } catch (e) {
    console.error("verifyIdToken (purchase-number):", e.message);
    return res.status(401).json({ error: "Invalid or expired token" });
  }

  const phoneRaw =
    req.body && req.body.phoneNumber != null
      ? String(req.body.phoneNumber).trim().replace(/\s/g, "")
      : "";
  if (!phoneRaw) {
    return res.status(400).json({ error: "Missing phoneNumber in JSON body" });
  }

  const db = firebaseAdmin.firestore();
  const ref = db.collection("users").doc(uid);
  const { FieldValue, Timestamp } = firebaseAdmin.firestore;

  let snap;
  try {
    snap = await ref.get();
  } catch (e) {
    console.error("POST /purchase-number get user:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }
  if (!snap.exists) {
    return res.status(404).json({ error: "User document not found" });
  }

  const d = snap.data() || {};
  const nowPurchase = new Date();
  if (!readEffectivePremiumUser(d, nowPurchase)) {
    return res.status(403).json({
      error: "Premium required",
      message: "Only premium users can purchase a number via this endpoint.",
    });
  }

  const primary = String(d.assigned_number ?? "").trim();
  const altLine = String(d.alt_assigned_number ?? "").trim();
  const hasPrimary = primary && primary.toLowerCase() !== "none";
  const hasAlt = altLine && altLine.toLowerCase() !== "none";

  if (hasPrimary && hasAlt) {
    return res.status(409).json({
      error: "Line limit reached",
      message: `You already have ${MAX_TWILIO_LINES_PREMIUM} Pro phone lines.`,
      max: MAX_TWILIO_LINES_PREMIUM,
    });
  }

  const nowDate = nowPurchase;
  const lineExpTs = Timestamp.fromDate(premiumLineExpiryFromUserDoc(d, nowDate));
  const expIso = lineExpTs.toDate().toISOString();

  let incoming;
  try {
    incoming = await purchaseIncomingUsLocal(uid, phoneRaw);
  } catch (e) {
    console.error("POST /purchase-number Twilio:", e);
    return res.status(400).json({ error: String(e.message || e) });
  }

  const e164 = String(incoming.phoneNumber || "").trim();
  if (!e164) {
    return res.status(400).json({ error: "Twilio returned empty phone number" });
  }

  if (!hasPrimary) {
    try {
    await ref.update({
      assigned_number: e164,
      phoneNumber: e164,
      virtual_number: e164,
      allocatedNumber: e164,
      number: e164,
      twilioIncomingPhoneSid: incoming.sid,
      twilioPhoneNumberSid: incoming.sid,
      twilioNumberAssignedAt: FieldValue.serverTimestamp(),
      number_assigned_at: FieldValue.serverTimestamp(),
      numberStatus: "active",
      number_status: "active",
      userNumber: e164,
      number_country: "US",
      number_created_at: FieldValue.serverTimestamp(),
      number_expiry_date: lineExpTs,
      expiry_date: lineExpTs,
      numberExpiry: lineExpTs,
      number_plan_type: String(d.premium_plan_type || "monthly"),
      number_tier: "premium",
      number_renew_ad_progress: 0,
    });
  } catch (e) {
    console.error("POST /purchase-number Firestore:", e);
      return res.status(500).json({
        error: String(e.message || e),
        warning:
          "Twilio number was purchased but profile update failed — check Twilio Console and Firestore manually.",
        twilioIncomingPhoneSid: incoming.sid,
        phoneNumber: e164,
      });
    }
    return res.status(200).json({
      ok: true,
      assigned_number: e164,
      slot: "primary",
      twilioIncomingPhoneSid: incoming.sid,
      number_status: "active",
      expiry_date: expIso,
      number_expiry_date: expIso,
    });
  }

  try {
    await ref.update({
      alt_assigned_number: e164,
      alt_twilioIncomingPhoneSid: incoming.sid,
      alt_twilioPhoneNumberSid: incoming.sid,
      alt_twilioNumberAssignedAt: FieldValue.serverTimestamp(),
      number_renew_ad_progress: 0,
    });
  } catch (e) {
    console.error("POST /purchase-number Firestore (alt):", e);
    return res.status(500).json({
      error: String(e.message || e),
      warning:
        "Twilio number was purchased but profile update failed — check Twilio Console and Firestore manually.",
      twilioIncomingPhoneSid: incoming.sid,
      phoneNumber: e164,
    });
  }

  return res.status(200).json({
    ok: true,
    assigned_number: e164,
    slot: "secondary",
    twilioIncomingPhoneSid: incoming.sid,
    number_status: "active",
    expiry_date: expIso,
    number_expiry_date: expIso,
  });
});

app.get("/assign-number", (_req, res) => {
  res.set("Allow", "POST");
  return res.status(405).json({
    error: "Method not allowed",
    message: "Use POST /assign-number with header Authorization: Bearer <Firebase ID token>",
  });
});

/**
 * POST /assign-number — provision a real US local Twilio number (secured).
 * - Body: `{ "planType": "…", "phoneNumber": "+1…" }` — `phoneNumber` from GET /available-numbers.
 * - Eligible if `isPremium` OR (free tier) lifetime ads ≥ min OR usable credits ≥ ASSIGN_NUMBER_MIN_CREDITS.
 * - Deducts plan credits (0 for premium) and sets `number_expiry_date`, `number_plan_type`.
 * - Purchases the chosen E.164 via Twilio, then updates Firestore.
 */
app.post("/assign-number", async (req, res) => {
  if (!firebaseAdmin) {
    return res.status(503).json({
      error: "Assign number not configured (set FIREBASE_SERVICE_ACCOUNT_JSON on the server)",
    });
  }
  const auth = req.headers.authorization || "";
  const m = /^Bearer\s+(.+)$/i.exec(auth);
  if (!m) {
    return res.status(401).json({ error: "Missing Authorization: Bearer <Firebase ID token>" });
  }
  let uid;
  try {
    const dec = await firebaseAdmin.auth().verifyIdToken(m[1]);
    uid = dec.uid;
  } catch (e) {
    console.error("verifyIdToken (assign-number):", e.message);
    return res.status(401).json({ error: "Invalid or expired token" });
  }

  const bodyUid =
    req.body && req.body.uid != null ? String(req.body.uid).trim() : "";
  if (bodyUid && bodyUid !== uid) {
    return res.status(403).json({ error: "uid does not match authenticated user" });
  }

  const db = firebaseAdmin.firestore();
  const ref = db.collection("users").doc(uid);

  let snap;
  try {
    snap = await ref.get();
  } catch (e) {
    console.error("assign-number get:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }

  if (!snap.exists) {
    return res.status(404).json({ error: "User document not found" });
  }

  const d = snap.data() || {};
  const nowAssign = new Date();
  const existingAssigned = String(d.assigned_number ?? "").trim();
  if (existingAssigned && existingAssigned.toLowerCase() !== "none") {
    const ne = readNumberExpiryDate(d);
    return res.status(200).json({
      ok: true,
      alreadyAssigned: true,
      assigned_number: existingAssigned,
      twilioIncomingPhoneSid: d.twilioIncomingPhoneSid || d.twilioPhoneNumberSid || null,
      number_expiry_date: ne ? ne.toISOString() : null,
      expiry_date: ne ? ne.toISOString() : null,
      number_plan_type: d.number_plan_type ?? null,
    });
  }

  if (countTwilioLines(d) >= maxTwilioLinesFor(d, nowAssign)) {
    return res.status(409).json({
      error: "Number limit reached",
      message: readEffectivePremiumUser(d, nowAssign)
        ? "Maximum phone lines for your account."
        : "Free accounts can have one phone line.",
      max: maxTwilioLinesFor(d, nowAssign),
    });
  }

  const planType = normalizePlanType(req.body && req.body.planType);
  if (!planType) {
    return res.status(400).json({
      error: "Missing or invalid planType",
      expected: ["daily", "weekly", "monthly", "yearly"],
    });
  }

  const premium = readEffectivePremiumUser(d, nowAssign);
  if (!premium) {
    return res.status(403).json({
      error: "Premium required",
      message: `Free accounts unlock an auto-assigned US line after ${NUMBER_UNLOCK_ADS_REQUIRED} rewarded ads in the app. Upgrade to Pro to pick a number from inventory.`,
    });
  }

  const usable = usableCreditsFromUserDoc(d);
  const adsLifetime = readLifetimeAdsWatched(d);
  const enoughCredits = true;
  const enoughAds = true;

  const planCredits = 0;

  let leaseMs = Number(PLAN_ASSIGN_MS[planType] ?? NaN);
  if (!Number.isFinite(leaseMs) || leaseMs <= 0) {
    return res.status(500).json({ error: "Plan duration configuration invalid" });
  }

  let tierReq = String(req.body?.numberTier ?? "")
    .trim()
    .toLowerCase();
  if (!tierReq) tierReq = "premium";
  if (tierReq === "normal") {
    return res.status(400).json({
      error: "Use POST /assign-free-number for Normal tier",
      hint: "POST /assign-number is for Pro users picking inventory (premium tier).",
    });
  }
  if (tierReq !== "vip" && tierReq !== "premium") {
    return res.status(400).json({
      error: "Invalid numberTier",
      expected: ["vip", "premium"],
    });
  }

  const phonePick =
    req.body && req.body.phoneNumber != null
      ? String(req.body.phoneNumber).trim().replace(/\s/g, "")
      : "";
  if (!phonePick) {
    return res.status(400).json({
      error: "Missing phoneNumber",
      hint: "GET /available-numbers, then POST the chosen E.164 in phoneNumber",
    });
  }

  let incoming;
  try {
    incoming = await purchaseIncomingUsLocal(uid, phonePick);
  } catch (e) {
    console.error("assign-number Twilio:", e);
    if (isTwilioNumberUnavailableError(e)) {
      return res.status(409).json({
        error: "NUMBER_UNAVAILABLE",
        code: "NUMBER_UNAVAILABLE",
        message: "Oops! This number was just taken. Please pick another one.",
      });
    }
    const status = Number(e.status);
    const http =
      e.http != null
        ? Number(e.http)
        : Number.isFinite(status) && status >= 400 && status < 600
          ? status
          : 502;
    return res.status(http).json({
      error: String(e.message || e),
    });
  }

  const e164 = String(incoming.phoneNumber || "").trim();
  if (!e164) {
    return res.status(500).json({ error: "Twilio returned empty phone number" });
  }

  const now = new Date();
  return respondAfterTwilioAssignSuccess(res, {
    uid,
    ref,
    incoming,
    e164,
    planType,
    planCredits,
    premium,
    leaseMs,
    now,
    usable,
    adsLifetime,
    enoughAds,
    enoughCredits,
    numberTier: tierReq,
    extraFirestore: {},
    extraResponse: { number_tier: tierReq },
  });
});

const CALL_CREDITS_PER_MINUTE = Number(process.env.CALL_CREDITS_PER_MINUTE || 10);
const CALL_CREDITS_PER_MINUTE_PREMIUM = Number(process.env.CALL_CREDITS_PER_MINUTE_PREMIUM || 15);

/** Matches Flutter [FirestoreUserService.isPremiumFromUserData]. */
function readIsPremium(d) {
  if (!d) return false;
  if (d.isPremium === true) return true;
  const t = String(d.subscription_tier ?? d.subscriptionTier ?? d.plan ?? "").toLowerCase();
  return t === "pro" || t === "premium";
}

/** Line lease end — prefers `numberExpiry`, then `expiry_date`, then `number_expiry_date`. */
function readNumberExpiryDate(d) {
  if (!d) return null;
  const keys = ["numberExpiry", "expiry_date", "number_expiry_date"];
  for (const k of keys) {
    const x = d[k];
    if (x && typeof x.toDate === "function") return x.toDate();
  }
  return null;
}

/**
 * Pro subscription end — prefers `expiry_date` (set by verify-payment), else same triplet as
 * [readNumberExpiryDate] for older docs.
 */
function readSubscriptionExpiryDate(d) {
  if (!d) return null;
  const ex = d.expiry_date;
  if (ex && typeof ex.toDate === "function") return ex.toDate();
  return readNumberExpiryDate(d);
}

/** True when doc flags say premium but subscription end is on or before [nowDate] (UTC wall clock). */
function isPremiumSubscriptionExpired(d, nowDate = new Date()) {
  if (!readIsPremium(d)) return false;
  const exp = readSubscriptionExpiryDate(d);
  if (!exp) return false;
  return exp.getTime() <= nowDate.getTime();
}

/** Premium for product / billing gates: Pro flag and subscription not past end (see [isPremiumSubscriptionExpired]). */
function readEffectivePremiumUser(d, nowDate = new Date()) {
  return readIsPremium(d) && !isPremiumSubscriptionExpired(d, nowDate);
}

/** Firestore fields written when subscription expiry demotes the user to free tier. */
const PREMIUM_SUBSCRIPTION_DEMOTE_FIELDS = {
  isPremium: false,
  subscription_tier: "free",
  subscriptionTier: "free",
};

/** Primary line status: `active` | `expired` (and legacy `number_status`). */
function readNumberLineStatus(d) {
  if (!d) return "";
  const a = d.numberStatus;
  if (typeof a === "string" && a.trim()) return a.trim().toLowerCase();
  const b = d.number_status;
  if (typeof b === "string" && b.trim()) return b.trim().toLowerCase();
  return "";
}

/** `normal` (free auto-assign) | `vip` (credit assign-number) | `premium` (Pro purchase). */
function readNumberTier(d, nowDate = new Date()) {
  if (!d) return "normal";
  const t = String(d.number_tier ?? d.numberTier ?? "").toLowerCase().trim();
  if (t === "normal" || t === "vip" || t === "premium") return t;
  const npt = String(d.number_plan_type ?? "").toLowerCase();
  if (npt === "browse_credits") return "vip";
  if (readEffectivePremiumUser(d, nowDate)) return "premium";
  return "normal";
}

function premiumLineExpiryFromUserDoc(d, nowDate) {
  const ex = readNumberExpiryDate(d);
  const plan = normalizePlanType(d.premium_plan_type) || "monthly";
  if (!ex || ex.getTime() <= nowDate.getTime()) {
    return subscriptionExpiryFromPlan(plan);
  }
  return ex;
}

/**
 * Outbound guard: if user has an assigned Twilio line and a stored expiry in the past, block.
 * No assigned line → allow (credit-only outbound).
 */
function assertAssignedNumberSubscriptionActive(d) {
  if (!d) return;
  const st = readNumberLineStatus(d);
  if (st === "expired") {
    const err = new Error("Assigned number has expired — get a new number in the app.");
    err.http = 403;
    err.code = "NUMBER_EXPIRED";
    throw err;
  }
  const assigned = String(d.assigned_number ?? d.phoneNumber ?? "").trim();
  if (!assigned || assigned.toLowerCase() === "none") return;
  const exp = readNumberExpiryDate(d);
  if (exp == null) return;
  const tier = readNumberTier(d, new Date());
  const graceMs = tier === "premium" ? PREMIUM_SUBSCRIPTION_GRACE_MS : 0;
  if (exp.getTime() + graceMs < Date.now()) {
    const err = new Error("Assigned number lease expired — renew your plan in the app.");
    err.http = 403;
    err.code = "NUMBER_EXPIRED";
    throw err;
  }
}

/**
 * Demote Firestore users whose Pro subscription end is in the past but `isPremium` was never cleared
 * (offline clients, missed writes). Uses [isPremiumSubscriptionExpired] / [readSubscriptionExpiryDate]
 * (`expiry_date` first, then number-lease fields — same as live routes).
 *
 * Queries (two passes, same pagination): `isPremium == true` (boolean) and `isPremium == "true"` (legacy string).
 */
async function runPremiumExpiryJanitor() {
  if (!firebaseAdmin) {
    console.warn("[premium-expiry-janitor] skipped — Firebase Admin not configured");
    return { skipped: true, scanned: 0, demoted: 0, errors: 0 };
  }
  const db = firebaseAdmin.firestore();
  const { FieldPath } = firebaseAdmin.firestore;
  const now = new Date();
  const pageSize = 400;
  const out = { scanned: 0, demoted: 0, errors: 0 };

  /**
   * @param {boolean|string} premiumEq — Firestore `isPremium` equality (boolean `true` or legacy `"true"`).
   */
  async function paginateDemote(premiumEq) {
    let lastDoc = null;
    for (;;) {
      let q = db
        .collection("users")
        .where("isPremium", "==", premiumEq)
        .orderBy(FieldPath.documentId())
        .limit(pageSize);
      if (lastDoc) {
        q = q.startAfter(lastDoc);
      }
      const snap = await q.get();
      if (snap.empty) {
        break;
      }
      for (const doc of snap.docs) {
        out.scanned += 1;
        const d = doc.data() || {};
        if (!readIsPremium(d)) {
          continue;
        }
        if (!isPremiumSubscriptionExpired(d, now)) {
          continue;
        }
        try {
          await doc.ref.update(PREMIUM_SUBSCRIPTION_DEMOTE_FIELDS);
          out.demoted += 1;
          console.log(`[premium-expiry-janitor] demoted uid=${doc.id}`);
        } catch (e) {
          out.errors += 1;
          console.error(`[premium-expiry-janitor] update failed uid=${doc.id}:`, e.message || e);
        }
      }
      lastDoc = snap.docs[snap.docs.length - 1];
      if (snap.size < pageSize) {
        break;
      }
    }
  }

  await paginateDemote(true);
  await paginateDemote("true");

  console.log(
    `[premium-expiry-janitor] done scanned=${out.scanned} demoted=${out.demoted} errors=${out.errors}`,
  );
  return out;
}

/**
 * Scheduled job: release Twilio numbers whose lease (`numberExpiry` / `expiry_date` / `number_expiry_date`) is in the past.
 * Runs on cron (default hourly UTC) — see NUMBER_JANITOR_CRON.
 */
async function runNumberLeaseJanitor() {
  if (!firebaseAdmin) {
    console.warn("[number-janitor] skipped — Firebase Admin not configured");
    return { candidates: 0, twilioReleased: 0, twilioErrors: 0, firestoreCleared: 0, firestoreErrors: 0 };
  }
  const db = firebaseAdmin.firestore();
  const nowTs = firebaseAdmin.firestore.Timestamp.now();
  const nowMs = Date.now();
  let s1;
  let s2;
  let s3;
  try {
    s1 = await db.collection("users").where("number_expiry_date", "<", nowTs).get();
    s2 = await db.collection("users").where("expiry_date", "<", nowTs).get();
    s3 = await db.collection("users").where("numberExpiry", "<", nowTs).get();
  } catch (e) {
    console.error("[number-janitor] Firestore query failed:", e.message || e);
    throw e;
  }

  const seen = new Set();
  const docs = [];
  for (const doc of [...s1.docs, ...s2.docs, ...s3.docs]) {
    if (seen.has(doc.id)) continue;
    seen.add(doc.id);
    docs.push(doc);
  }

  let twilioReleased = 0;
  let twilioErrors = 0;
  let firestoreCleared = 0;
  let firestoreErrors = 0;

  async function tryRemoveSidWithReuse(e164, sidRaw) {
    const sid = String(sidRaw ?? "").trim();
    if (!sid) return;
    try {
      await twilioClient.incomingPhoneNumbers(sid).remove();
      twilioReleased += 1;
      const e = String(e164 ?? "").trim();
      if (e && e.toLowerCase() !== "none") {
        await recordReleasedNumber(e);
      }
    } catch (e) {
      twilioErrors += 1;
      console.error(`[number-janitor] Twilio remove failed sid=${sid}:`, e.message || e);
    }
  }

  for (const doc of docs) {
    const d = doc.data() || {};
    const leaseEnd = readNumberExpiryDate(d);
    if (leaseEnd == null) {
      continue;
    }
    const tier = readNumberTier(d, new Date(nowMs));
    const graceMs = tier === "premium" ? PREMIUM_SUBSCRIPTION_GRACE_MS : 0;
    if (leaseEnd.getTime() + graceMs >= nowMs) {
      continue;
    }

    const assigned = String(d.assigned_number ?? d.phoneNumber ?? "").trim();
    const altNum = String(d.alt_assigned_number ?? "").trim();
    const hasLine =
      (assigned && assigned.toLowerCase() !== "none") ||
      (altNum && altNum.toLowerCase() !== "none");

    if (!hasLine) {
      try {
        await doc.ref.update({
          number_expiry_date: null,
          expiry_date: null,
          numberExpiry: null,
          number_plan_type: null,
          phoneNumber: null,
          numberStatus: null,
          number_status: null,
        });
      } catch (e) {
        console.error(`[number-janitor] orphan expiry cleanup failed uid=${doc.id}:`, e.message || e);
      }
      continue;
    }

    await tryRemoveSidWithReuse(assigned, d.twilioIncomingPhoneSid || d.twilioPhoneNumberSid);
    await tryRemoveSidWithReuse(altNum, d.alt_twilioIncomingPhoneSid || d.alt_twilioPhoneNumberSid);

    if (
      !String(d.twilioIncomingPhoneSid || d.twilioPhoneNumberSid || "").trim() &&
      !String(d.alt_twilioIncomingPhoneSid || d.alt_twilioPhoneNumberSid || "").trim()
    ) {
      console.warn(`[number-janitor] expired lease but no Twilio SID on user ${doc.id} — clearing Firestore only`);
    }

    try {
      await doc.ref.update({
        assigned_number: null,
        phoneNumber: null,
        virtual_number: null,
        allocatedNumber: null,
        number: null,
        twilioIncomingPhoneSid: null,
        twilioPhoneNumberSid: null,
        twilioNumberAssignedAt: null,
        alt_assigned_number: null,
        alt_twilioIncomingPhoneSid: null,
        alt_twilioPhoneNumberSid: null,
        alt_twilioNumberAssignedAt: null,
        number_expiry_date: null,
        expiry_date: null,
        numberExpiry: null,
        number_plan_type: null,
        userNumber: null,
        number_country: null,
        number_created_at: null,
        number_renew_ad_progress: 0,
        number_tier: null,
        numberStatus: "expired",
        number_status: "expired",
      });
      firestoreCleared += 1;
    } catch (e) {
      firestoreErrors += 1;
      console.error(`[number-janitor] Firestore clear failed uid=${doc.id}:`, e.message || e);
    }
  }

  console.log(
    `[number-janitor] lease_query_hits=${docs.length} twilio_released=${twilioReleased} twilio_errors=${twilioErrors} firestore_cleared=${firestoreCleared} firestore_errors=${firestoreErrors}`,
  );
  return {
    candidates: docs.length,
    twilioReleased,
    twilioErrors,
    firestoreCleared,
    firestoreErrors,
  };
}

/** Non-empty Firebase Auth uid — all billing writes use `users/{uid}`. */
function requireFirebaseUid(uid) {
  const u = String(uid || "").trim();
  if (!u) {
    throw Object.assign(new Error("Missing or empty user id for billing"), { http: 400 });
  }
  return u;
}

function parseTwilioDurationSeconds(body) {
  const raw =
    body.Duration ??
    body.CallDuration ??
    body.DialCallDuration ??
    body.RecordingDuration ??
    body.duration ??
    body.callDuration ??
    "0";
  const n = Number.parseInt(String(raw), 10);
  return Number.isFinite(n) && n >= 0 ? n : 0;
}

/** Outbound Voice SDK: `From` is `client:<identity>`; identity is Firebase UID from `/token`. */
function resolveUidFromTwilioStatus(body, query) {
  const q = query && (query.uid || query.userId);
  if (q && String(q).trim()) return String(q).trim();
  const from = String(body.From || "");
  const m = /^client:(.+)$/i.exec(from);
  if (m) return m[1].trim();
  return null;
}

/** Matches Flutter [CreditsPolicy] live tick amounts (10 = connect pulse, 1 = periodic). */
const ALLOWED_LIVE_TICK_AMOUNTS = new Set([1, 10]);

/**
 * TalkFree Tier-2 settlement (server truth; backup: Twilio POST /call-status if app offline).
 *
 * Math (1 live tick = 6s = 1 credit):
 * - finalCharge = ceil(durationSec / 6)  e.g. 12s → 2, 0s → 0
 * - prepaid = liveDeductedCredits from POST /call-live-tick (every 6s × 1)
 * - remainder = finalCharge - prepaid → deduct from user; if prepaid > finalCharge, refund to paidCredits
 *
 * Firestore: `users/{uid}` fields paidCredits, rewardCredits, credits; history in `call_history/{callSid}`.
 */
async function settleOutboundCallBill({
  uid: uidIn,
  callSid,
  durationSec,
  from,
  to,
  twilioCallStatus,
  source,
}) {
  if (!firebaseAdmin) {
    throw new Error("Firebase not configured");
  }
  const uid = requireFirebaseUid(uidIn);
  const db = firebaseAdmin.firestore();
  const { FieldValue } = firebaseAdmin.firestore;

  const ds = Number(durationSec) || 0;

  await db.runTransaction(async (t) => {
    const userRef = db.collection("users").doc(uid);
    const statsRef = db.collection("user_stats").doc(uid);
    const historyRef = userRef.collection("call_history").doc(callSid);
    const liveRef = userRef.collection("voice_active_calls").doc(callSid);

    const existing = await t.get(historyRef);
    if (existing.exists && existing.data()?.settled === true) {
      return;
    }

    const userSnap = await t.get(userRef);
    if (!userSnap.exists) {
      throw Object.assign(new Error("User document missing"), { http: 404 });
    }

    await t.get(statsRef);

    const liveSnap = await t.get(liveRef);
    const prepaid = Number(liveSnap.exists ? liveSnap.data()?.liveDeductedCredits || 0 : 0);

    const d = userSnap.data();
    const now = new Date();
    const premium = readEffectivePremiumUser(d, now);
    /** Billed tick units: free = 1 credit / 6s; premium = 7 credits/min (align with ~8571ms live ticks). */
    const tickUnits = premium ? Math.ceil((ds * CALL_CREDITS_PER_MINUTE_PREMIUM) / 60) : Math.ceil(ds / 6);
    const billCredits = tickUnits;
    let paid = Number(d.paidCredits ?? 0);
    let reward = Number(d.rewardCredits ?? 0);
    const expTs = d.rewardCreditsExpiresAt;
    if (reward > 0 && expTs && typeof expTs.toDate === "function" && expTs.toDate() < now) {
      paid += reward;
      reward = 0;
    }
    if (d.paidCredits === undefined && d.credits != null) {
      paid = Number(d.credits);
      reward = 0;
    }

    let remainder = billCredits - prepaid;

    /** Credits returned to **paidCredits** only (audit: rewards vs purchased). */
    let refundToPaidCredits = 0;
    if (remainder < 0) {
      const refund = -remainder;
      paid += refund;
      refundToPaidCredits = refund;
      remainder = 0;
    }

    let usable = paid + reward;
    const charge = remainder;
    let creditsChargedThisSettle = 0;
    if (charge > 0 && usable > 0) {
      creditsChargedThisSettle = usable < charge ? usable : charge;
      let left = creditsChargedThisSettle;
      const takeReward = left < reward ? left : reward;
      reward -= takeReward;
      left -= takeReward;
      paid -= left;
      usable = paid + reward;
    }

    let rewardExpOut = null;
    if (reward > 0) {
      rewardExpOut = expTs && expTs.toDate && expTs.toDate() >= now ? expTs : null;
    }

    const totalCreditsOut = paid + reward;
    console.log(
      `[billing] settle user=${uid} callSid=${callSid} source=${source} durationSec=${ds} ` +
        `premium=${premium} tickUnits=${tickUnits} billCredits=${billCredits} prepaid=${prepaid} refundToPaidCredits=${refundToPaidCredits} ` +
        `remainderCharge=${charge} creditsAppliedThisSettle=${creditsChargedThisSettle} balanceAfter=${totalCreditsOut}`,
    );

    t.update(userRef, {
      paidCredits: paid,
      rewardCredits: reward,
      rewardCreditsExpiresAt: rewardExpOut,
      credits: totalCreditsOut,
      totalOutboundCalls: FieldValue.increment(1),
      totalCallTalkSeconds: FieldValue.increment(ds),
    });

    // Fractional minutes = trend; whole-minute ceil = billing-ish sidecar (`total_cost_estimated_rounded`).
    const talkMinutes = ds > 0 ? ds / 60 : 0;
    const callCostInr =
      talkMinutes > 0 && Number.isFinite(EST_COST_INR_PER_CALL_MINUTE)
        ? talkMinutes * EST_COST_INR_PER_CALL_MINUTE
        : 0;
    const wholeMinutes = ds > 0 ? Math.ceil(ds / 60) : 0;
    const callCostRounded =
      wholeMinutes > 0 && Number.isFinite(EST_COST_INR_PER_CALL_MINUTE)
        ? wholeMinutes * EST_COST_INR_PER_CALL_MINUTE
        : 0;
    t.set(
      statsRef,
      {
        total_call_minutes: FieldValue.increment(talkMinutes),
        total_cost_estimated: FieldValue.increment(callCostInr),
        total_cost_estimated_rounded: FieldValue.increment(callCostRounded),
        stats_updated_at: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    t.set(
      historyRef,
      {
        firebaseUid: uid,
        callSid,
        direction: "outgoing",
        twilioCallStatus: String(twilioCallStatus || "completed"),
        durationSeconds: ds,
        billedSixSecondTicks: tickUnits,
        creditsPerMinute: premium ? CALL_CREDITS_PER_MINUTE_PREMIUM : CALL_CREDITS_PER_MINUTE,
        finalCharge: billCredits,
        isPremium: premium,
        prepaidAppliedFromLiveTicks: prepaid,
        refundToPaidCredits,
        creditsCharged: creditsChargedThisSettle,
        creditsAttempted: charge,
        partialDeduction: charge > 0 && creditsChargedThisSettle < charge,
        from,
        to,
        settled: true,
        settledAt: FieldValue.serverTimestamp(),
        source: source || "unknown",
      },
      { merge: true },
    );

    t.delete(liveRef);
  });
}

/**
 * POST /call-live-tick — Firebase Bearer; JSON `{ "callSid": "CA...", "amount": 1|10 }` (legacy).
 * **Trust:** debit is always **1** prepaid credit per request; `amount` is validated but not used for the debit
 * (prevents inflated client ticks). `POST /sync-call-billing` / Twilio settlement reconciles final duration.
 */
app.post("/call-live-tick", async (req, res) => {
  if (!firebaseAdmin) {
    return res.status(503).json({ error: "Firebase not configured" });
  }
  const auth = req.headers.authorization || "";
  const bm = /^Bearer\s+(.+)$/i.exec(auth);
  if (!bm) {
    return res.status(401).json({ error: "Missing Authorization: Bearer <Firebase ID token>" });
  }
  let uid;
  try {
    uid = requireFirebaseUid((await firebaseAdmin.auth().verifyIdToken(bm[1])).uid);
  } catch (e) {
    return res.status(401).json({ error: "Invalid or expired token" });
  }

  /** Block outbound billing ticks if the user's leased US number has expired (see POST /assign-number). */
  try {
    const preSnap = await firebaseAdmin.firestore().collection("users").doc(uid).get();
    if (preSnap.exists) {
      assertAssignedNumberSubscriptionActive(preSnap.data());
    }
  } catch (e) {
    if (e.http === 403) {
      return res.status(403).json({
        error: e.message,
        code: e.code || "NUMBER_EXPIRED",
      });
    }
    console.error("/call-live-tick subscription check:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }

  const callSid = String(req.body?.callSid || req.body?.CallSid || "").trim();
  const clientAmount = Number(req.body?.amount);
  if (!callSid) {
    return res.status(400).json({ error: "Missing callSid" });
  }
  if (!Number.isFinite(clientAmount) || !ALLOWED_LIVE_TICK_AMOUNTS.has(clientAmount)) {
    return res.status(400).json({ error: "Invalid amount (allowed: 1 or 10)" });
  }

  let call;
  try {
    call = await twilioClient.calls(callSid).fetch();
  } catch (e) {
    console.warn("/call-live-tick: Twilio fetch failed", e.message);
    return res.status(400).json({ error: "Could not fetch call" });
  }
  const from = String(call.from || "");
  const cm = /^client:(.+)$/i.exec(from);
  if (!cm || cm[1].trim() !== uid) {
    return res.status(403).json({ error: "Call does not belong to this user" });
  }

  const db = firebaseAdmin.firestore();
  const { FieldValue } = firebaseAdmin.firestore;

  try {
    await db.runTransaction(async (t) => {
      const userRef = db.collection("users").doc(uid);
      const liveRef = userRef.collection("voice_active_calls").doc(callSid);
      const userSnap = await t.get(userRef);
      if (!userSnap.exists) {
        throw Object.assign(new Error("User document missing"), { http: 404 });
      }

      const d = userSnap.data();
      const nowTick = new Date();
      const premiumExpired = isPremiumSubscriptionExpired(d, nowTick);
      const premium = readEffectivePremiumUser(d, nowTick);
      const debit = 1;
      let paid = Number(d.paidCredits ?? 0);
      let reward = Number(d.rewardCredits ?? 0);
      const expTs = d.rewardCreditsExpiresAt;
      if (reward > 0 && expTs && typeof expTs.toDate === "function" && expTs.toDate() < nowTick) {
        paid += reward;
        reward = 0;
      }
      if (d.paidCredits === undefined && d.credits != null) {
        paid = Number(d.credits);
        reward = 0;
      }

      let usable = paid + reward;
      if (usable < debit) {
        throw Object.assign(new Error("Insufficient credits"), { http: 402 });
      }

      let left = debit;
      const takeReward = left < reward ? left : reward;
      reward -= takeReward;
      left -= takeReward;
      paid -= left;
      usable = paid + reward;

      let rewardExpOut = null;
      if (reward > 0) {
        rewardExpOut = expTs && expTs.toDate && expTs.toDate() >= nowTick ? expTs : null;
      }

      const bal = paid + reward;
      if (clientAmount !== 1) {
        console.warn(
          `[billing] call-live-tick clientAmount=${clientAmount} ignored; debit=${debit} user=${uid} callSid=${callSid}`,
        );
      }
      console.log(
        `[billing] call-live-tick user=${uid} callSid=${callSid} premium=${premium} premiumExpired=${premiumExpired} ` +
          `clientAmount=${clientAmount} debit=${debit} balanceAfter=${bal}`,
      );
      const tickPatch = {
        paidCredits: paid,
        rewardCredits: reward,
        rewardCreditsExpiresAt: rewardExpOut,
        credits: bal,
      };
      if (premiumExpired) {
        Object.assign(tickPatch, PREMIUM_SUBSCRIPTION_DEMOTE_FIELDS);
      }
      t.update(userRef, tickPatch);
      t.set(
        liveRef,
        {
          firebaseUid: uid,
          liveDeductedCredits: FieldValue.increment(debit),
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    });
  } catch (e) {
    const code = e.http || 500;
    if (code === 402) {
      return res.status(402).json({ error: "Insufficient credits" });
    }
    if (code === 404) {
      return res.status(404).json({ error: "User not found" });
    }
    console.error("/call-live-tick:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }
  return res.status(200).json({ ok: true });
});

/**
 * POST /sync-call-billing — Firebase Bearer; JSON `{ "callSid": "CA..." }`.
 * Fetches Twilio call duration and runs the same settlement as Twilio `/call-status` (idempotent).
 */
app.post("/sync-call-billing", async (req, res) => {
  if (!firebaseAdmin) {
    return res.status(503).json({ error: "Firebase not configured" });
  }
  const auth = req.headers.authorization || "";
  const bm = /^Bearer\s+(.+)$/i.exec(auth);
  if (!bm) {
    return res.status(401).json({ error: "Missing Authorization: Bearer <Firebase ID token>" });
  }
  let uid;
  try {
    uid = requireFirebaseUid((await firebaseAdmin.auth().verifyIdToken(bm[1])).uid);
  } catch (e) {
    return res.status(401).json({ error: "Invalid or expired token" });
  }

  const callSid = String(req.body?.callSid || req.body?.CallSid || "").trim();
  if (!callSid) {
    return res.status(400).json({ error: "Missing callSid" });
  }

  let call;
  let durationSec = 0;
  try {
    for (let attempt = 0; attempt < 8; attempt++) {
      call = await twilioClient.calls(callSid).fetch();
      const durationRaw = Number.parseInt(String(call.duration != null ? call.duration : "0"), 10);
      durationSec = Number.isFinite(durationRaw) ? durationRaw : 0;
      const st = String(call.status || "");
      if (durationSec > 0 || st === "completed" || st === "canceled" || st === "failed") {
        break;
      }
      await new Promise((r) => setTimeout(r, 600));
    }
  } catch (e) {
    console.warn("/sync-call-billing: Twilio fetch failed", e.message);
    return res.status(400).json({ error: "Could not fetch call" });
  }
  const from = String(call.from || "");
  const cm = /^client:(.+)$/i.exec(from);
  if (!cm || cm[1].trim() !== uid) {
    return res.status(403).json({ error: "Call does not belong to this user" });
  }

  const to = String(call.to || "");
  console.log(
    `[billing] sync-call-billing user=${uid} callSid=${callSid} twilioStatus=${call.status} durationSec=${durationSec}`,
  );

  try {
    await settleOutboundCallBill({
      uid,
      callSid,
      durationSec,
      from,
      to,
      twilioCallStatus: String(call.status || "completed"),
      source: "sync_call_billing",
    });
  } catch (e) {
    const code = e.http || 500;
    if (code === 404) {
      return res.status(200).json({ ok: true, skipped: true });
    }
    console.error("/sync-call-billing:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }
  return res.status(200).json({ ok: true });
});

/**
 * Twilio StatusCallback — set in Twilio Console (Voice app / number) to:
 * `https://<PUBLIC_BASE_URL>/call-status`
 */
app.post("/call-status", async (req, res) => {
  const canonicalUrl = `${publicBase}/call-status`;
  const sig = req.get("X-Twilio-Signature") || "";
  if (process.env.SKIP_TWILIO_SIGNATURE !== "1" && TWILIO_AUTH_TOKEN) {
    const ok = twilio.validateRequest(TWILIO_AUTH_TOKEN, sig, canonicalUrl, req.body);
    if (!ok) {
      console.warn("/call-status: invalid Twilio signature");
      return res.status(403).send("Forbidden");
    }
  }

  const body = req.body || {};
  const status = String(body.CallStatus || body.Callstatus || "").toLowerCase();
  if (status !== "completed") {
    return res.status(200).type("text/plain").send("OK");
  }

  if (!firebaseAdmin) {
    console.warn("/call-status: FIREBASE_SERVICE_ACCOUNT_JSON unset — cannot bill");
    return res.status(503).type("text/plain").send("Firebase not configured");
  }

  const callSid = String(body.CallSid || "").trim();
  if (!callSid) {
    return res.status(400).type("text/plain").send("Missing CallSid");
  }

  const uidRaw = resolveUidFromTwilioStatus(body, req.query);
  if (!uidRaw) {
    console.warn(
      "/call-status: could not resolve user (need From=client:<firebaseUid> on Voice SDK calls)",
      "From=",
      body.From,
      "keys=",
      Object.keys(body || {}),
    );
    return res.status(200).type("text/plain").send("OK");
  }

  let uid;
  try {
    uid = requireFirebaseUid(uidRaw);
  } catch (e) {
    console.warn("/call-status: invalid uid", uidRaw);
    return res.status(200).type("text/plain").send("OK");
  }

  const durationSec = parseTwilioDurationSeconds(body);
  const from = String(body.From || "");
  const to = String(body.To || "");

  console.log(
    `[billing] call-status webhook user=${uid} callSid=${callSid} durationSec=${durationSec} CallStatus=${body.CallStatus}`,
  );

  try {
    await settleOutboundCallBill({
      uid,
      callSid,
      durationSec,
      from,
      to,
      twilioCallStatus: String(body.CallStatus || "completed"),
      source: "twilio_status_callback",
    });
  } catch (e) {
    const code = e.http || 500;
    if (code === 404) {
      return res.status(200).type("text/plain").send("OK");
    }
    console.error("/call-status:", e);
    return res.status(500).type("text/plain").send("Error");
  }

  return res.status(200).type("text/plain").send("OK");
});

/**
 * POST /terminate-call — Firebase Bearer token; JSON `{ "callSid": "CA..." }`.
 * Ends an in-progress Twilio call (same account as Voice SDK). Verifies `From` is `client:<uid>`.
 */
app.post("/terminate-call", async (req, res) => {
  if (!firebaseAdmin) {
    return res.status(503).json({ error: "Firebase not configured" });
  }
  const auth = req.headers.authorization || "";
  const m = /^Bearer\s+(.+)$/i.exec(auth);
  if (!m) {
    return res.status(401).json({ error: "Missing Authorization: Bearer <Firebase ID token>" });
  }
  let uid;
  try {
    uid = (await firebaseAdmin.auth().verifyIdToken(m[1])).uid;
  } catch (e) {
    return res.status(401).json({ error: "Invalid or expired token" });
  }

  const callSid = String(req.body?.callSid || req.body?.CallSid || "").trim();
  if (!callSid) {
    return res.status(400).json({ error: "Missing callSid" });
  }

  try {
    const call = await twilioClient.calls(callSid).fetch();
    const from = String(call.from || "");
    const cm = /^client:(.+)$/i.exec(from);
    if (!cm || cm[1].trim() !== uid) {
      console.warn("/terminate-call: From mismatch", from, uid);
      return res.status(403).json({ error: "Call does not belong to this user" });
    }
    await twilioClient.calls(callSid).update({ status: "completed" });
  } catch (e) {
    console.error("/terminate-call:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }
  return res.status(200).json({ ok: true });
});

app.get("/send-sms", (_req, res) => {
  res.set("Allow", "POST");
  return res.status(405).json({
    error: "Method not allowed",
    message: "Use POST /send-sms with Authorization: Bearer <Firebase ID token> and JSON { \"to\", \"body\" }",
  });
});

/**
 * POST /jobs/run-number-janitor — optional HTTP cron (Render). Header `X-Cron-Secret` must match `CRON_SECRET`.
 */
app.post("/jobs/run-number-janitor", async (req, res) => {
  const secret = String(process.env.CRON_SECRET || "").trim();
  if (!secret) {
    return res.status(503).json({ error: "CRON_SECRET not configured" });
  }
  const got = String(req.headers["x-cron-secret"] ?? "").trim();
  if (got !== secret) {
    return res.status(403).json({ error: "Forbidden" });
  }
  try {
    const r = await runNumberLeaseJanitor();
    return res.status(200).json({ ok: true, ...r });
  } catch (e) {
    console.error("/jobs/run-number-janitor:", e);
    return res.status(500).json({ error: String(e.message || e) });
  }
});

/**
 * POST /jobs/run-premium-expiry-janitor — optional HTTP cron (Render). Header `X-Cron-Secret` must match `CRON_SECRET`.
 * Demotes `isPremium` users past [readSubscriptionExpiryDate] (see [runPremiumExpiryJanitor]).
 *
 * Alias: POST `/jobs/premium-expiry-janitor` (same handler) — avoids 404 when cron URL omits `run-`.
 */
async function handlePremiumExpiryJanitorHttp(req, res) {
  const secret = String(process.env.CRON_SECRET || "").trim();
  if (!secret) {
    return res.status(503).json({ error: "CRON_SECRET not configured" });
  }
  const got = String(req.headers["x-cron-secret"] ?? "").trim();
  if (got !== secret) {
    return res.status(403).json({ error: "Forbidden" });
  }
  try {
    const r = await runPremiumExpiryJanitor();
    return res.status(200).json({ ok: true, ...r });
  } catch (e) {
    console.error(`${req.path || "/jobs/run-premium-expiry-janitor"}:`, e);
    return res.status(500).json({ error: String(e.message || e) });
  }
}

app.post("/jobs/run-premium-expiry-janitor", handlePremiumExpiryJanitorHttp);
app.post("/jobs/premium-expiry-janitor", handlePremiumExpiryJanitorHttp);

/**
 * POST /renew-number — Bearer; JSON `{ "mode": "ads" | "credits" }`. Extends primary line `expiry_date`.
 */
app.post("/renew-number", async (req, res) => {
  if (!firebaseAdmin) {
    return res.status(503).json({ error: "Firebase Admin not configured" });
  }
  const auth = req.headers.authorization || "";
  const m = /^Bearer\s+(.+)$/i.exec(auth);
  if (!m) {
    return res.status(401).json({ error: "Missing Authorization: Bearer <Firebase ID token>" });
  }
  let uid;
  try {
    uid = (await firebaseAdmin.auth().verifyIdToken(m[1])).uid;
  } catch (e) {
    return res.status(401).json({ error: "Invalid or expired token" });
  }
  const mode = String(req.body?.mode ?? "").trim().toLowerCase();
  if (mode !== "ads" && mode !== "credits") {
    return res.status(400).json({ error: "Invalid mode", expected: ["ads", "credits"] });
  }

  const db = firebaseAdmin.firestore();
  const ref = db.collection("users").doc(uid);
  const { Timestamp } = firebaseAdmin.firestore;

  let snap;
  try {
    snap = await ref.get();
  } catch (e) {
    return res.status(500).json({ error: String(e.message || e) });
  }
  if (!snap.exists) {
    return res.status(404).json({ error: "User not found" });
  }
  const d = snap.data() || {};
  const assigned = String(d.assigned_number ?? d.phoneNumber ?? "").trim();
  if (!assigned || assigned.toLowerCase() === "none") {
    return res.status(400).json({ error: "No assigned number to renew" });
  }

  const now = new Date();
  const cur = readNumberExpiryDate(d);
  if (!cur) {
    return res.status(400).json({ error: "No lease expiry on file — contact support." });
  }

  const dayKey = now.toISOString().slice(0, 10);
  let renewDay = String(d.number_renew_utc_day ?? "").trim();
  let renewCount = Number(d.number_renew_count_day ?? 0);
  if (!Number.isFinite(renewCount)) renewCount = 0;
  if (renewDay !== dayKey) {
    renewCount = 0;
  }
  if (MAX_RENEWALS_PER_DAY > 0 && renewCount >= MAX_RENEWALS_PER_DAY) {
    return res.status(403).json({
      error: "Daily renew limit reached",
      code: "RENEW_DAILY_LIMIT",
      maxRenewalsPerDay: MAX_RENEWALS_PER_DAY,
      renewalsUsedToday: renewCount,
    });
  }

  const premium = readEffectivePremiumUser(d, now);
  const baseMs = Math.max(now.getTime(), cur.getTime());
  const extendFreeMs = FREE_TIER_NUMBER_LEASE_MS;
  const planKey = normalizePlanType(d.premium_plan_type) || "monthly";
  const extendPremMs = Number(PLAN_ASSIGN_MS[planKey] || PLAN_ASSIGN_MS.monthly);

  if (mode === "ads") {
    const prog = Number(d.number_renew_ad_progress || 0);
    if (prog < NUMBER_RENEW_ADS_REQUIRED) {
      return res.status(403).json({
        error: "Not enough rewarded ads toward renew",
        number_renew_ad_progress: prog,
        requiredAds: NUMBER_RENEW_ADS_REQUIRED,
      });
    }
    const newExp = new Date(baseMs + (premium ? extendPremMs : extendFreeMs));
    const ts = Timestamp.fromDate(newExp);
    await ref.update({
      number_expiry_date: ts,
      expiry_date: ts,
      numberExpiry: ts,
      number_renew_utc_day: dayKey,
      number_renew_count_day: renewCount + 1,
      number_renew_ad_progress: 0,
    });
    return res.status(200).json({
      ok: true,
      mode: "ads",
      expiry_date: newExp.toISOString(),
      number_expiry_date: newExp.toISOString(),
      numberExpiry: newExp.toISOString(),
      maxRenewalsPerDay: MAX_RENEWALS_PER_DAY,
      renewalsUsedToday: renewCount + 1,
    });
  }

  const usable = usableCreditsFromUserDoc(d);
  if (usable < NUMBER_RENEW_CREDITS) {
    return res.status(402).json({
      error: "Insufficient credits to renew",
      requiredCredits: NUMBER_RENEW_CREDITS,
      usableCredits: usable,
    });
  }

  let paid = Number(d.paidCredits ?? 0);
  let reward = Number(d.rewardCredits ?? 0);
  if (d.paidCredits === undefined && d.credits != null) {
    paid = Number(d.credits);
    reward = 0;
  }
  const expTs = d.rewardCreditsExpiresAt;
  if (reward > 0 && expTs && expTs.toDate && expTs.toDate() < now) {
    paid += reward;
    reward = 0;
  }
  let left = NUMBER_RENEW_CREDITS;
  const takeReward = left < reward ? left : reward;
  reward -= takeReward;
  left -= takeReward;
  paid -= left;
  let rewardExpOut = null;
  if (reward > 0) {
    rewardExpOut = expTs && expTs.toDate && expTs.toDate() >= now ? expTs : null;
  }
  const totalOut = paid + reward;
  const newExp = new Date(baseMs + (premium ? extendPremMs : extendFreeMs));
  const ts = Timestamp.fromDate(newExp);
  await ref.update({
    paidCredits: paid,
    rewardCredits: reward,
    rewardCreditsExpiresAt: rewardExpOut,
    credits: totalOut,
    number_expiry_date: ts,
    expiry_date: ts,
    numberExpiry: ts,
    number_renew_utc_day: dayKey,
    number_renew_count_day: renewCount + 1,
    number_renew_ad_progress: 0,
  });
  return res.status(200).json({
    ok: true,
    mode: "credits",
    creditsDeducted: NUMBER_RENEW_CREDITS,
    newBalance: totalOut,
    expiry_date: newExp.toISOString(),
    number_expiry_date: newExp.toISOString(),
    numberExpiry: newExp.toISOString(),
    maxRenewalsPerDay: MAX_RENEWALS_PER_DAY,
    renewalsUsedToday: renewCount + 1,
  });
});

/**
 * POST /send-sms — Firebase Bearer token; JSON `{ "to": "+...", "body": "..." }`.
 * - `From`: user's `assigned_number` in Firestore if valid E.164, else `TWILIO_CALLER_ID`.
 * - Logs each step for Render logs (URL, From, To, payload size).
 * - Twilio errors: logs exact code + message (e.g. 21608 unverified trial destination).
 */
app.post("/send-sms", async (req, res) => {
  const routeUrl = `${publicBase}/send-sms`;
  console.log("[send-sms] step 1: request URL (PUBLIC_BASE_URL)", routeUrl);

  if (!firebaseAdmin) {
    console.error("[send-sms] Firebase Admin not configured — cannot verify caller");
    return res.status(503).json({
      error: "SMS API not configured (set FIREBASE_SERVICE_ACCOUNT_JSON on the server)",
    });
  }

  let fallbackCaller;
  try {
    fallbackCaller = getTwilioCallerIdOrThrow("POST /send-sms");
  } catch (e) {
    return res.status(500).json({
      error: String(e.message || e),
      code: e.code || "MISSING_TWILIO_CALLER_ID",
    });
  }
  console.log("[send-sms] step 2: TWILIO_CALLER_ID from env (fallback) present, length=", String(fallbackCaller).length);

  const auth = req.headers.authorization || "";
  const m = /^Bearer\s+(.+)$/i.exec(auth);
  if (!m) {
    console.warn("[send-sms] missing Authorization Bearer");
    return res.status(401).json({ error: "Missing Authorization: Bearer <Firebase ID token>" });
  }

  let uid;
  try {
    const dec = await firebaseAdmin.auth().verifyIdToken(m[1]);
    uid = dec.uid;
  } catch (e) {
    console.error("[send-sms] verifyIdToken:", e.message);
    return res.status(401).json({ error: "Invalid or expired token" });
  }
  console.log("[send-sms] step 3: Firebase uid", uid);

  const toRaw = req.body && (req.body.to ?? req.body.To);
  const bodyText = req.body && (req.body.body ?? req.body.Body ?? req.body.message ?? "");
  const payloadPreview = {
    toRaw: toRaw != null ? String(toRaw).slice(0, 32) : null,
    bodyLength: String(bodyText).length,
  };
  console.log("[send-sms] step 4: payload (preview)", payloadPreview);

  const to = toE164(toRaw);
  const body = String(bodyText).trim();

  if (!to || !/^\+[1-9]\d{8,14}$/.test(to)) {
    console.error("[send-sms] invalid To after E.164 normalize:", { toRaw, to });
    return res.status(400).json({
      error: "Invalid or missing `to` — use E.164 (e.g. +15551234567)",
      toNormalized: to || null,
    });
  }
  if (!body) {
    console.error("[send-sms] empty body");
    return res.status(400).json({ error: "Missing `body` (message text)" });
  }

  const db = firebaseAdmin.firestore();
  let userData = {};
  try {
    const snap = await db.collection("users").doc(uid).get();
    userData = snap.exists ? snap.data() : {};
  } catch (e) {
    console.error("[send-sms] Firestore read users/" + uid + ":", e.message);
    return res.status(500).json({ error: "Could not load user profile" });
  }

  const resolved = resolveOutgoingSmsFrom(userData, fallbackCaller);
  const from = resolved.from;
  console.log("[send-sms] step 5: From number (E.164)", from, "| source:", resolved.source);
  console.log("[send-sms] step 6: To number (E.164)", to);
  console.log("[send-sms] step 7: Body chars", body.length);

  if (!from || !/^\+[1-9]\d{8,14}$/.test(from)) {
    console.error("[send-sms] invalid From after resolve:", { from, resolved });
    return res.status(500).json({
      error: "Could not resolve a valid From number — check assigned_number or TWILIO_CALLER_ID",
    });
  }

  if (resolved.source === "firestore:assigned_number") {
    try {
      assertAssignedNumberSubscriptionActive(userData);
    } catch (e) {
      if (e && e.code === "NUMBER_EXPIRED") {
        return res.status(403).json({
          error: e.code,
          message: e.message || "Line lease expired — renew in the app.",
        });
      }
      if (e && e.http >= 400 && e.http < 500) {
        return res.status(e.http).json({ error: String(e.message || e) });
      }
      throw e;
    }
  }

  const premiumSms = readEffectivePremiumUser(userData, new Date());

  let smsDeducted = 0;
  let newBalanceAfterSms = null;
  let otpAdsDebited = 0;
  try {
    if (premiumSms) {
      if (SMS_OUTBOUND_CREDIT_COST > 0) {
        const dr = await deductCreditsForSms(uid, SMS_OUTBOUND_CREDIT_COST);
        newBalanceAfterSms = dr.newBalance;
        smsDeducted = SMS_OUTBOUND_CREDIT_COST;
      }
    } else {
      const refOtp = db.collection("users").doc(uid);
      await db.runTransaction(async (t) => {
        const snap = await t.get(refOtp);
        const ud = snap.exists ? snap.data() || {} : {};
        const otpNow = readOtpAdsProgress(ud);
        if (otpNow < OTP_ADS_REQUIRED_PER_SMS) {
          throw Object.assign(new Error("INSUFFICIENT_OTP_ADS"), {
            http: 402,
            otpAdsProgress: otpNow,
            requiredOtpAds: OTP_ADS_REQUIRED_PER_SMS,
          });
        }
        t.update(refOtp, {
          otp_ads_progress: otpNow - OTP_ADS_REQUIRED_PER_SMS,
        });
      });
      otpAdsDebited = OTP_ADS_REQUIRED_PER_SMS;
    }
  } catch (deductErr) {
    if (deductErr && deductErr.http === 402) {
      if (String(deductErr.message || "") === "INSUFFICIENT_OTP_ADS") {
        return res.status(402).json({
          error: "Insufficient rewarded ads for SMS",
          message: `Free tier: watch ${OTP_ADS_REQUIRED_PER_SMS} rewarded ads per outbound SMS (no credits used).`,
          otpAdsProgress: deductErr.otpAdsProgress,
          requiredOtpAds: deductErr.requiredOtpAds,
        });
      }
      return res.status(402).json({
        error: String(deductErr.message || "Insufficient credits"),
        usableCredits: deductErr.usableCredits,
        requiredCredits: deductErr.requiredCredits,
      });
    }
    console.error("[send-sms] charge (credits or OTP ads):", deductErr);
    return res.status(500).json({ error: "Could not apply SMS charge" });
  }

  try {
    const msg = await twilioClient.messages.create({
      from,
      to,
      body,
    });
    console.log("[send-sms] step 8: Twilio OK sid=", msg.sid, "status=", msg.status);
    try {
      const { FieldValue } = firebaseAdmin.firestore;
      const smsCost = Number.isFinite(EST_COST_INR_PER_OUTBOUND_SMS)
        ? EST_COST_INR_PER_OUTBOUND_SMS
        : 0;
      await db
        .collection("user_stats")
        .doc(uid)
        .set(
          {
            total_sms_sent: FieldValue.increment(1),
            total_cost_estimated: FieldValue.increment(smsCost),
            stats_updated_at: FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
    } catch (statsErr) {
      console.warn("[send-sms] user_stats:", statsErr.message || statsErr);
    }
    return res.status(200).json({
      ok: true,
      sid: msg.sid,
      status: msg.status,
      from,
      to,
      fromSource: resolved.source,
      creditsDeducted: smsDeducted || undefined,
      newBalance: newBalanceAfterSms,
      otpAdsDebited: otpAdsDebited || undefined,
    });
  } catch (err) {
    if (smsDeducted > 0) {
      try {
        await refundSmsCredits(uid, smsDeducted);
      } catch (re) {
        console.error("[send-sms] refund after Twilio failure:", re);
      }
    }
    if (otpAdsDebited > 0) {
      try {
        await refundOtpAdsProgress(uid, otpAdsDebited);
      } catch (re) {
        console.error("[send-sms] OTP ad refund after Twilio failure:", re);
      }
    }
    const code = err.code;
    const message = err.message;
    const status = err.status;
    const moreInfo = err.moreInfo;
    console.error("[send-sms] Twilio messages.create FAILED:", {
      code,
      message,
      status,
      moreInfo,
      from,
      to,
    });
    return res.status(502).json({
      error: message || String(err),
      twilioCode: code != null ? String(code) : undefined,
      twilioStatus: status,
      moreInfo: moreInfo || undefined,
      from,
      to,
    });
  }
});

// After API routes — avoids any edge case where static assets shadow POST handlers on some hosts.
app.use(express.static(path.join(__dirname, "public")));

const server = app.listen(Number(PORT), () => {
  console.log(`TalkFree voice server listening on port ${PORT}`);
  console.log(`PUBLIC_BASE_URL (normalized): ${publicBase}`);
  console.log(`Outbound SMS (app → Twilio): POST ${publicBase}/send-sms`);
  console.log(`Inbound SMS webhook (Twilio): ${publicBase}/sms-webhook`);

  if (process.env.DISABLE_NUMBER_JANITOR === "1") {
    console.log("[number-janitor] disabled (DISABLE_NUMBER_JANITOR=1)");
  } else if (!firebaseAdmin) {
    console.warn("[number-janitor] not scheduled — Firebase Admin not configured");
  } else {
    const schedule = String(process.env.NUMBER_JANITOR_CRON || "0 * * * *").trim();
    cron.schedule(
      schedule,
      () => {
        runNumberLeaseJanitor().catch((e) =>
          console.error("[number-janitor] unhandled:", e.message || e),
        );
      },
      { timezone: "UTC" },
    );
    console.log(`[number-janitor] scheduled (cron="${schedule}" UTC) — releases expired Twilio numbers`);
  }

  if (process.env.DISABLE_PREMIUM_EXPIRY_JANITOR === "1") {
    console.log("[premium-expiry-janitor] disabled (DISABLE_PREMIUM_EXPIRY_JANITOR=1)");
  } else if (!firebaseAdmin) {
    console.warn("[premium-expiry-janitor] not scheduled — Firebase Admin not configured");
  } else {
    const premSchedule = String(process.env.PREMIUM_EXPIRY_JANITOR_CRON || "15 * * * *").trim();
    cron.schedule(
      premSchedule,
      () => {
        runPremiumExpiryJanitor().catch((e) =>
          console.error("[premium-expiry-janitor] unhandled:", e.message || e),
        );
      },
      { timezone: "UTC" },
    );
    console.log(
      `[premium-expiry-janitor] scheduled (cron="${premSchedule}" UTC) — demotes expired Pro subscriptions`,
    );
  }
});
server.on("error", (err) => {
  if (err.code === "EADDRINUSE") {
    console.error(`Port ${PORT} is already in use. Change PORT in .env or stop the other process.`);
    if (String(PORT) === "3000") {
      console.error("From server folder try: npm run free-port   then   npm start");
    }
    console.error(
      "PowerShell: Get-NetTCPConnection -LocalPort " +
        PORT +
        " -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }",
    );
    process.exit(1);
  }
  throw err;
});
