# Contacts and fighter calls

The app opens in landscape on a playable solo fighter scene. The fighter on the left can be posed and moved while the right-side menu offers **Quick Fight**, recent contacts, and **Demo Fight**. Quick Fight pairs two searching guest devices through Nakama and needs no phone number or SMS. Contacts opens the portrait Faceoff friends list. Selecting a registered friend returns to the arena with a right-side action terminal where **Start Fight** is enabled and voice-only **Call** and **Message** are disabled. Demo Fight controls both fighters locally. Online players control only their assigned fighter.

## Account and invitations

Settings contains phone-number sign-up and **Invite friends**. Phone sign-up requires a real Twilio Verify service configured on the Nakama server. Device authentication is used only to bootstrap verification requests. It does not grant access to contacts, messaging, or invitations. Custom authentication checks the verification code with Twilio before selecting the phone identity. Public custom-link authentication and identity-linking bypasses are blocked; the invite resolver returns only prefill metadata from an opaque, expiring handle.

Set these values in the server's ignored `.env.production` and redeploy:

```dotenv
TWILIO_ACCOUNT_SID=your_account_sid
TWILIO_AUTH_TOKEN=your_auth_token
TWILIO_VERIFY_SERVICE_SID=your_verify_service_sid
TWILIO_VERIFY_CHANNEL=sms
```

SMS is a metered provider feature, so keep the Twilio account on the free trial while testing only with its verified recipients in the signup country. A Danish `+45` recipient cannot complete verification on the current German trial account; use an upgraded account with Denmark enabled or another provider for that test. The server limits sends to 5 per bootstrap account per hour and 30 across the server per day, and verification attempts to 6 per number per minute. It also keeps a conservative monthly estimate in Nakama: `FACE_OFF_SMS_ALERT_EUR=6` reports an in-app alert when crossed, and `FACE_OFF_SMS_BUDGET_EUR=10` blocks new verification sends. Set `FACE_OFF_SMS_ESTIMATE_EUR` above the expected per-message cost when in doubt. These names are retained for compatibility when the optional WhatsApp channel is selected. This is a protective estimate; Twilio's billing console and UsageTrigger remain the source of truth for the final invoice. Missing provider configuration fails closed with an explanation in Settings.

Phone verification is the recommended account path for contact discovery and recovery, but it is not required to play. **Quick Fight** works online with Nakama device authentication, and **Demo Fight** works locally. Guest players cannot use private contact discovery, persistent messaging, or targeted invitations. Never treat the invite handle itself as authentication. Twilio Verify also supports WhatsApp, but it requires a WhatsApp sender and trial recipients still have to be verified, so it is not a way around the current Denmark trial restriction. See the [Verify WhatsApp requirements](https://www.twilio.com/docs/verify/whatsapp) and [trial WhatsApp limits](https://www.twilio.com/docs/usage/trials/try-out-whatsapp).

Invite friends opens a separate **All contacts** screen and asks Android for Contacts access only after the user taps it. The screen is searchable and does not make phone contacts look like Faceoff friends. The bridge uses Godot's permission dispatcher on Android's UI thread, normalizes numbers to international format using the SIM country (device country fallback), and reads up to 500 phone entries. Users should store a country prefix for contacts outside their SIM country. Names stay on the device; phone numbers are sent over TLS for matching after account verification.

The All contacts screen starts invitations by channel: SMS, WhatsApp, or Telegram. Faceoff opens the chosen app directly and the player selects the recipient once there. A number can also be entered directly when it is not saved in Android Contacts. Spaces, parentheses, hyphens, dots, and a `00` prefix are normalized to international format before the SMS composer opens. For an authenticated, verified inviter, the server creates a short-lived opaque invite handle and keeps the phone number in private storage. The message includes a `faceoff://invite/<token>` link; after installation the app resolves it and prefills Profile, but the recipient must still request and enter a fresh verification code. After that OTP succeeds, the client claims the handle and the server creates mutual contact records, so the inviter can call without another contact refresh. The link is not an authentication or call-access token. The Android bridge attaches a copy of the installed APK using a restricted FileProvider URI. This supports the current standalone APK builds; split APK distribution from a future Play AAB needs a store or download link. Set `faceoff/invite_download_url` in `project.godot` only after a real download is published. No Play Store listing is required: both people can install the same signed APK and verify their phone numbers.

## Lobby rules

- An outgoing call has Cancel. The caller cannot accept or decline it.
- An incoming call has Accept and Decline. The recipient cannot cancel the outgoing request.
- Ringing expires after 60 seconds. Busy recipients reject a second invitation.
- Acceptance is an atomic server transition. Only the two invited accounts can join the resulting authoritative match.
- Both clients wait for the server's two-player readiness event, choose one fighter on the shared selection screen, and exchange the roster IDs before entering the arena.
- During connection, End call replaces the ringing controls. Leaving or disconnecting ends the shared room.
- Decline, Cancel, expiry and network errors never start a demo as a fallback.

Messages and pings use persistent Nakama notifications. Missed notifications are loaded in pages of 100, with a saved cursor and up to 20 pages per connection; the client stores the latest 100 conversation entries per peer locally. This is an initial messaging implementation, without delivery receipts or a full paginated history.

## Audio and camera

Microphone preference starts enabled. Android microphone permission is requested only when an accepted call enters the arena, or when enabling audio during a call. Muting stops outgoing capture, and leaving clears capture/playback buffers. Initial voice uses bounded 16 kHz mono PCM frames through the authenticated match socket. Transport delivery has automated coverage; physical Android capture, playback, latency, and echo handling still need a two-device test. This is not an end-to-end encrypted media implementation.

Face video is unavailable. Video icons are disabled in conversation and arena screens, and CAMERA permission is absent from the Android manifest. A future video upgrade negotiation must keep the audio fight running when declined. No camera permission or fake successful video call is presented now.

Background push and lock-screen incoming-call UI are not implemented. For this build, both players must keep the app open and connected to receive a ringing call immediately. Persistent messages appear when the recipient reconnects.

## Local verification

Use the isolated `faceoff-dev` Docker stack on port 7352. The integration test seeds synthetic verified profiles directly into its local database, never through a production authentication bypass:

```bash
node tests/integration/social_lobby.mjs
```

This checks discovery, invite-link resolution, role restrictions, decline/cancel, stranger rejection, two-player readiness, replies, and the real Godot clients' notification, ownership, pose and voice transport paths. No real SMS is sent. `tests/test_fighter_lobby_layout.gd` covers separate Accept/Decline geometry and outgoing/incoming controls in both orientations. `tests/test_contacts_home.gd` covers friend filtering, All contacts, search, history, scroll activation guarding, and invite-phone prefilling.

## Deployment status

The Nakama transport and current authoritative match module are deployed on `nakamas://2-56-96-171.sslip.io`. A two-guest Quick Fight probe passes matchmaking, fighter selection, state replication, hits, and authoritative guard damage. Twilio Verify credentials still need to be supplied before phone sign-up can work there. The invite-link changes in this checkout still need a deliberate social-module redeploy, and the Android deep-link changes need a new APK. Building an APK alone does not update the VPS. A physical two-phone test remains for audio capture, Android permissions, and latency tuning before calling the experience fully production-ready.
