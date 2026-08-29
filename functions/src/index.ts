import * as admin from "firebase-admin";
import {HttpsError, onCall} from "firebase-functions/v2/https";

admin.initializeApp();

/**
 * Legacy callable — **disabled**. Ad rewards must use the secured Node API
 * `POST /grant-reward` (Firebase ID token) so credits, caps, and OTP/number
 * progress stay server-authoritative.
 */
export const grantRewardedAdCredits = onCall(
  {region: "us-central1"},
  async () => {
    throw new HttpsError(
      "failed-precondition",
      "AD_REWARDS_USE_HTTP_API: Use POST /grant-reward on the TalkFree voice server.",
    );
  },
);
