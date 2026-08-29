# TalkFree — Firestore `users/{uid}` (rewarded ads)

## Canonical fields (preferred)

| Field | Type | Purpose |
|--------|------|---------|
| `ad_progress` | number | **0–3** — ads completed toward the next **4-ad** grant. At the 4th ad, app calls **`POST /grant-reward`**, then resets to **0**. |
| `ads_watched_today` | number | Count for **today** (see `last_reset_date`). Max **24** / day. |
| `last_reset_date` | string | `YYYY-MM-DD` (UTC) — when `ads_watched_today` last applied; resets daily count when the calendar day changes. |
| `last_ad_timestamp` | timestamp | Last completed rewarded ad — **20s** cooldown before another ad (client). |
| `last_grant_reward_at` | timestamp | Set by **server** on successful `POST /grant-reward` — **20s** between grants. |
| `last_grant_at_ads_watched_today` | number | Milestone key: `ads_watched_today` value when last grant was applied (prevents double-claim). |

## Legacy mirrors (still written for older clients)

`adRewardCycleCount` ↔ `ad_progress` · `adRewardsCount` ↔ `ads_watched_today` · `adRewardsDayKey` ↔ `last_reset_date` · `lastAdRewardAt` ↔ `last_ad_timestamp`

## Credits

| Field | Type | Purpose |
|--------|------|---------|
| `credits` | number | Denormalized `paidCredits + rewardCredits`. |
| `paidCredits` | number | Purchased bucket. |
| `rewardCredits` | number | Ad bucket; **only** server `/grant-reward` should add (e.g. **+10** per 4-ad milestone). |
| `rewardCreditsExpiresAt` | timestamp | Reward TTL (e.g. +24h). |

## `users/{uid}/call_history/{callSid}` (server — Twilio `/call-status`)

Written when Twilio reports **`completed`**: bill **ceil(durationSeconds / 60) × 10** credits (configurable on server via `CALL_CREDITS_PER_MINUTE`), idempotent per `CallSid`.

| Field | Type | Purpose |
|--------|------|---------|
| `callSid` | string | Twilio Call SID (document id). |
| `durationSeconds` | number | Twilio call length (seconds). |
| `billedMinutes` | number | `ceil(durationSeconds / 60)`. |
| `creditsPerMinute` | number | Rate used (default **10**). |
| `creditsAttempted` | number | `billedMinutes × creditsPerMinute`. |
| `creditsCharged` | number | Actually deducted (capped by balance). |
| `partialDeduction` | bool | True if balance was lower than attempted charge. |
| `from` / `to` | string | Twilio `From` / `To`. |
| `settled` | bool | **true** when processed (prevents duplicate billing). |
| `settledAt` | timestamp | Server time. |
| `source` | string | `twilio_status_callback`. |

## Flow

1. User finishes a **Rewarded Ad** → `AdService.loadAndShowRewardedAd` returns `true`.
2. App runs **`registerRewardedAdWatch`**: updates `ad_progress`, `ads_watched_today`, `last_ad_timestamp`, enforces **24/day** and **20s** cooldown.
3. On every **4th** ad in a cycle → **`POST /grant-reward`** (Firebase Bearer token) → Node adds **10 credits** securely.
