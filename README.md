# Live Glass — TikTok Live Recorder for iPhone (100% phone workflow)

Records TikTok lives at **max quality** (source stream, no re-encode), automatically,
24/7 in the background — straight from your iPhone 13. No PC needed at any point.
Everything here is **free**.

**Design:** on iOS 26/27 you get Apple's **native Liquid Glass** UI automatically; on your
iOS 17 it shows a handcrafted glass look that matches the same design language. (Your
iPhone 13 supports iOS 26 — updating gives you the true native Liquid Glass.)

---

## What it does

- **Watchlist**: add usernames (e.g. `charlidamelio` or a full profile link)
- **Auto-record**: polls every 15–120 s (default 30 s); the moment someone goes live it
starts capturing the stream — usually **within ~30 seconds** of them going live
- **Max quality**: picks the best quality TikTok serves (Original/`_or4` → highest HLS
variant, up to 1080p), and remuxes **losslessly** to MP4 — zero quality loss from
re-encoding. Three native remux strategies are tried in order, so recordings come out
as `.mp4` almost always. As a last resort the raw stream is kept (`.ts` for fMP4-odd
streams still plays **in-app**; only rare `.flv` needs VLC) and a one-tap
**"To MP4"** button converts old/odd files losslessly right on the phone
- **24/7 in background**: silent-audio keep-alive keeps the app alive with the screen
off (enable it once — it's on by default)
- **Extras you'll like**: live preview player, notifications when a recording starts/
saves, per-user auto-rec toggle, record up to 2–4 lives at once, auto-split into
15/30/60-min parts, low-storage guard, WiFi-only mode, keep-screen-awake, share to
Photos/Files/VLC, auto-resumes monitoring after a crash or reboot relaunch

## Reality check (read once)

| Thing | Truth |
| --- | --- |
| Free signing | Free Apple ID certs expire **every 7 days** → re-sign the app weekly in KravaSign (a paid KravaSign cert = 1 year, no re-signing) |
| 3-app limit | Free Apple ID allows max 3 sideloaded apps installed at once |
| Data usage | ~0.5–2 GB per hour per recording at max quality → use WiFi |
| Battery | Screen off + keep-alive ≈ a few %/hour on WiFi while recording; keep the phone plugged for true 24/7 |
| TikTok anti-bot | TikTok sometimes walls its web endpoints. The app uses 4 fallbacks automatically; if it still fails, paste cookies in Settings → Advanced |
| Region/age-locked lives | Need cookies (Settings → Advanced) |

---

## Setup — iPhone only, ~15 minutes, one time

### 1. Get the files onto your iPhone
1. In this chat, download **`LiveGlass_iPhone_Kit.zip`** (Safari puts it in Files → Downloads)
2. In the Files app: tap the zip → it extracts to `LiveGlass_iPhone_Kit/`

### 2. Create a GitHub repo (this is where the IPA gets built — free)
1. In Safari, go to **github.com** and sign up / log in (free)
2. Tap **+** (top right) → **New repository**
3. Name it anything, e.g. `liveglass` — set it **Public** (public = free unlimited builds)
4. Tap **Create repository**

### 3. Upload the project files
1. On the empty repo page tap **"uploading an existing file"** (or Add file → Upload files)
2. Tap **choose your files** → in the Files picker go to
`Downloads → LiveGlass_iPhone_Kit → repo-files` → tap **Select** (top right) →
select **all files** in that folder → tap **Open/Add**
3. Tap **Commit changes**

> The `zz-workflow-...yml` file is NOT uploaded — it's your clipboard holder for the next step.

### 4. Add the build workflow (copy-paste, 2 min)
1. Back in the repo (Files app): open `zz-workflow-paste-into-github.yml` →
tap and hold → **Select All** → **Copy**
2. In GitHub (Safari): **Add file → Create new file**
3. In the filename box type exactly: `.github/workflows/build.yml`
(typing the `/` creates the folders)
4. Tap into the empty file body → paste (hold → Paste)
5. **Commit changes**

### 5. Build the IPA (free, on GitHub's Macs)
1. Repo → **Actions** tab → if asked, tap **"I understand my workflows, go ahead and enable them"**
2. Tap **Build Unsigned IPA** → **Run workflow** → **Run workflow**
3. Wait ~3–6 minutes. Tap the finished run → scroll to **Artifacts** →
download `LiveGlass-unsigned-ipa-…` → Safari saves it to Files → Downloads
4. In Files: the artifact is a zip → tap it to extract → inside is **`LiveGlass-unsigned.ipa`**

(If the `macos-26` runner is ever unavailable, edit `.github/workflows/build.yml` and
change `runs-on: macos-26` → `runs-on: macos-15`, then re-run. Rebuilds any time you
change code: just re-run the workflow.)

### 6. Sign & install with KravaSign (already have it — perfect)
1. Open **KravaSign** → its Files/import → pick `LiveGlass-unsigned.ipa` from Downloads
2. Sign with your certificate:
- **Free Apple ID**: create/use a signing certificate from your Apple ID
(valid **7 days** — set a weekly reminder to re-sign; the app keeps its data
across re-signs as long as you don't delete it)
- **KravaSign certificate** (if you have one): imports the same way, valid much longer
3. Install. If iOS complains about the developer, go to
**Settings → General → VPN & Device Management** → trust your certificate

### 7. First launch
1. Allow **Notifications** when asked (recommended)
2. Type a TikTok username → **Check** → try **Preview** while they're live
3. Toggle **Monitoring** on (top card) — you're live 24/7 now. Keep the phone on WiFi,
plugged in, screen is fine to lock.
4. Optional: Settings → enable WiFi-only, auto-save to Photos, split parts, cookies

---

## Where the recordings go

Inside the app: **Recordings** (folder icon, top-left) — every mp4/ts file has a
**Play** button that plays it right in the app. Also visible in
**Files → On My iPhone → Live Glass → Recordings**. Share them out
via the Share button (Photos, VLC, iCloud, Telegram, …).

| Ending | Meaning |
| --- | --- |
| `.mp4` | Losslessly remuxed — plays everywhere (in-app, Photos, share sheet) |
| `.ts` | Raw fallback — still plays in-app (tap Play) and converts to MP4 with the **To MP4** button |
| `.flv` | Only when TikTok served no HLS — needs VLC (free), can't be converted on-device |

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Build fails on Actions | Open the failed run's log; most often a file was missed in step 3 — compare repo file list with `repo-files/` |
| "TikTok is blocking this request" | Settings → Advanced → paste cookies from a browser logged into tiktok.com (e.g. `tt-target-idc=useast2a; sessionid=…`) |
| Status stuck "Checking" | TikTok walled that route; it retries other routes automatically every poll |
| Recording is `.ts` | Rare fallback — it plays in-app (tap Play); for a universal file tap **To MP4** on that row |
| Recording is `.flv` | TikTok served no HLS for that stream — watch in VLC (free); the app prefers HLS automatically next time |
| App stopped opening | Free cert expired (7 days) → re-sign in KravaSign |
| Recording stopped overnight | Check the phone stayed on WiFi + power; check the app wasn't deleted/re-signed; monitoring auto-resumes when you reopen the app |
| Audio from other apps stops | The keep-alive session takes audio focus; toggle keep-alive off if you need music (monitoring then pauses when backgrounded) |

## Legal / etiquette

Recording public streams for **personal archival** is between you and TikTok's ToS —
don't re-upload other people's content without permission. No login/credentials of
yours are ever sent anywhere except TikTok itself.
