# Releasing the iPhone app

CI tests, archives, signs and uploads. A person sets up App Store Connect
once, then tags each release. This file lists that person's steps in order.
Checked against Apple's pages on 12 October 2026; Apple moves menus, so
trust the screen if it differs.

| What | Value |
|---|---|
| Seller | Sourceful Labs AB (reg. no. 559382-0458), Kalmar, Sweden |
| Team ID | `L66M368PZ6` |
| Bundle IDs | `energy.ftw.app`, `energy.ftw.app.widgets` |
| App Group | `group.energy.ftw.app` |
| Workflow | [`.github/workflows/ios-release.yml`](../.github/workflows/ios-release.yml) |
| Store texts | [`store/`](store/) |
| Privacy and support | `https://ftw.energy/privacy`, `https://ftw.energy/support` ([srcfl/ftw-web](https://github.com/srcfl/ftw-web)) |

## How a build travels

1. A tag `ios-v1.2.3` (or **Run workflow** on the *iOS release* workflow)
   starts the job on GitHub's `xcode-27` runner.
2. It runs `swift test`, then archives with Xcode 27.0 and the iOS 27 SDK.
   The version comes from the tag (a manual run uses `MARKETING_VERSION` in
   `FTW.xcconfig`); the build number is the run number, with `.2`, `.3` on a
   re-run.
3. Xcode signs with the team through the API key and uploads with
   [`ExportOptions.plist`](ExportOptions.plist) (`app-store-connect`,
   `upload`). The build shows in TestFlight once Apple has processed it.

Without the three secrets the job archives unsigned and reports
"Upload skipped". A pull request that changes the workflow or the export
options always takes that path, so it proves the archive without a key.

Apple has required the iOS 26 SDK for uploads since 28 April 2026 and
requires the iOS 27 SDK from April 2027. Xcode 27 meets both.

## Once, before the first upload

### 1. Agreements, identifiers and links

- The Account Holder accepts the latest Apple Developer Program License
  Agreement under **Business**. Until then App Store Connect refuses new
  apps, and the API key stops working. A free app needs no Paid Apps
  Agreement.
- Register the App IDs, the App Group and Associated Domains as
  [README](../README.md#status-iphone-2026-10-12) lists under "Manual
  steps before a phone build". Building once in Xcode, signed in to the
  team, does this too.
- `https://app.ftw.energy/.well-known/apple-app-site-association` must
  answer before review: passkeys and pairing links need it
  ([srcfl/ftw-webapp#77](https://github.com/srcfl/ftw-webapp/pull/77)).
  On 12 October 2026 it answered 404.
- `ftw.energy` must serve the website. On 12 October 2026 it had no
  address record, and the Cloudflare Pages project `ftw` served only
  `ftw.sourceful.energy`. In Cloudflare: **Workers & Pages → ftw → Custom
  domains → Set up a custom domain → `ftw.energy`**. Then check:

  ```bash
  curl -sI https://ftw.energy/privacy
  ```

  If `ftw.energy` stays off, replace it with `ftw.sourceful.energy` in
  `store/*/privacy-url.txt`, `support-url.txt` and `marketing-url.txt`.

### 2. Create the app

**App Store Connect → Apps → (+) → New App**

| Field | Enter |
|---|---|
| Platforms | iOS |
| Name | `FTW` (see below) |
| Primary Language | English (U.S.) |
| Bundle ID | `energy.ftw.app` |
| SKU | `energy.ftw.app` (cannot change later) |
| User Access | Full Access |

English is the primary language, so every country without its own text
shows English. Then add **Swedish** under the localization menu in App
Information.

**The name.** The iTunes Search API found no live app named exactly "FTW"
in the Swedish or US store on 12 October 2026 (nearest: "FTW Fly", "FTW -
Step Competition", "FTW Fitness", "FTW Trading"). The search sees only
live apps, and Apple also holds names for apps not yet released, so the New
App dialog gives the final answer. If "FTW" is taken, try in this order;
none was in use:

1. `FTW Energy` (Swedish page: `FTW Energi`)
2. `FTW – Home Energy` (`FTW – Hemmets energi`)
3. `FTW by Sourceful`

The name under the icon stays "FTW" whatever the store name.

### 3. App Information

**Apps → FTW → App Information** (under General), for each language:

| Field | Value |
|---|---|
| Subtitle | `store/<lang>/subtitle.txt` |
| Category | Primary **Utilities**, no secondary. Not Health & Fitness: that asks for a medical device declaration. |
| Content Rights | No third-party content: the app shows only the user's own box. |
| Age Rating | **Set Up Age Ratings**. Answer No to every capability (web access, user-generated content, social media, messaging, advertising) and None to every content item. Age Categories and Override: Not Applicable. Result: 4+. |
| Copyright | `2026 Sourceful Labs AB` |
| Privacy Policy URL (App Privacy) | `store/<lang>/privacy-url.txt` |

### 4. Trader status under the EU Digital Services Act

EU users see the trader's address, phone and email on the product page.
Apple removes apps without trader status from the EU stores.

1. **Business → Agreements → Compliance → Digital Services Act → Complete
   Compliance Requirements → This is a trader account.**
2. The address comes from Sourceful Labs AB's D-U-N-S Number. Enter a
   phone number and an email address, and confirm each with the code Apple
   sends.
3. Upload a document that proves the company name and address, such as a
   registration certificate from Bolagsverket.
4. For the app: **App Information → App Store Regulations and Permits →
   Digital Services Act → Edit → trader**.

Sourceful Labs AB already sells "Sourceful Energy" in the EU stores, so
the account may already be a trader account; check step 1 first. If that
app lives under another team, this team needs its own.

**Decide:** which email and phone EU users see. The only Sourceful address
published today is `support@sourceful.energy` on
[sourceful.energy/contact](https://www.sourceful.energy/contact), which
ftw-web and FTW's SUPPORT.md link to. No phone number is published.

### 5. App Privacy

**Apps → FTW → App Privacy → Get Started → "No, we do not collect data
from this app" → Save → Publish.**

Apple's test: data is collected when it leaves the device "in a way that
allows you and/or your third-party partners to access it for a period
longer than what is necessary to service the transmitted request in real
time". In M1:

- The app's only network peer is `wss://relay.ftw.energy`. Everything it
  sends is end-to-end encrypted to the user's box; the relay has no key.
- The relay keeps no traffic. Its access log drops addresses and
  rendezvous handles (`relay/deploy/Caddyfile` in ftw-webapp).
- No analytics, ads, third-party code or tracking.

One edge: when the relay fails to proxy a connection, Caddy's error log
may still hold the client address and handle (rotated, 3 × 10 MB).
Filtering that log too would remove the doubt; that change belongs in
ftw-webapp.

The privacy manifest (`PrivacyInfo.xcprivacy`) comes with the store-ready
branch. Both answers change when FTW Cloud ships: it will hold readable
data the user turns on.

### 6. Encryption and export

The store-ready branch sets `ITSAppUsesNonExemptEncryption` in
`FTW-Info.plist`; with the key set, App Store Connect asks nothing per
build. Without it, answer under **App Information → App Encryption
Documentation (+)**, or **Manage** next to a build in TestFlight.

What to answer: FTWKit builds Noise IK from CryptoKit alone (X25519,
ChaCha20-Poly1305, SHA-256, HKDF). Apple's table says encryption "limited
to that within the Apple operating system" needs no documentation, and no
French declaration.

**Decide with counsel:** Apple notes that an app using exempt encryption
"might alternatively be required to submit a year-end self-classification
report to the U.S. government", and that US export law applies wherever
the company sits.

### 7. Price and countries

**Monetization → Pricing and Availability**

1. **Price Schedule → Add Pricing**: base country Sweden, price Free.
2. **App Availability → Set Up Availability → All Countries or Regions**
   (175, and new ones as Apple adds them).
3. Remove **China mainland**. It needs an ICP Filing Number in App
   Information that matches a filing with China's MIIT, which in practice
   takes a Chinese entity or partner. Without it the version stops at
   "ICP Filing Number Missing". (The iTunes lookup shows "Sourceful
   Energy" in the Chinese store. If Sourceful holds a filing, enter it and
   keep China.)
4. Untick **Apple silicon Mac** and **Apple Vision Pro**. Apple publishes
   iPhone apps there by default; M1 is iPhone only.

Other countries, checked for a free 4+ utility that is not a game:

| Where | Rule | For FTW |
|---|---|---|
| South Korea, Vietnam | Game ratings and licences | Games only. Nothing to do. |
| Brazil | Tax forms | Only for developers in Brazil. |
| Australia, Brazil, Singapore | 18+ download checks | Not for a 4+ app. |
| Texas, Utah, Louisiana | Age assurance for new accounts (Declared Age Range API) | **Decide with counsel.** M1 has no accounts and no age-dependent content. |
| Russia | — | "Sourceful Energy" is not in the Russian store. **Decide** whether FTW follows. |

### 8. API key and GitHub secrets

**Users and Access → Integrations → App Store Connect API → Team Keys →
Generate API Key**

- Name: `GitHub ftw-app release`.
- Access: **Admin**. App Manager is not enough: Apple's roles table gives
  cloud-managed distribution certificates to Account Holder and Admin, and
  other roles only through a per-user setting that team keys cannot have.
  The runner has no certificate of its own, so the export needs one from
  the cloud. Role and name cannot change after creation.
- Download the `.p8` file. Apple offers it once.
- The Key ID is in the key's row; the Issuer ID is at the top of the page.

Keep the secrets in a GitHub environment that only `main` and release tags
can use, since an Admin key can do much more than upload builds:

1. **srcfl/ftw-app → Settings → Environments → New environment →
   `app-store`.**
2. **Deployment branches and tags → Selected branches and tags**: add
   branch `main` and tag `ios-v*`. Optionally add yourself as a required
   reviewer.
3. Add the secrets there:

   ```bash
   gh secret set ASC_KEY_ID --env app-store --repo srcfl/ftw-app
   ```

   ```bash
   gh secret set ASC_ISSUER_ID --env app-store --repo srcfl/ftw-app
   ```

   ```bash
   gh secret set ASC_KEY_P8 --env app-store --repo srcfl/ftw-app < AuthKey_XXXXXXXXXX.p8
   ```

4. Delete the `.p8` from your disk, or keep it in a password manager.

Each run on a clean runner may create an "Apple Development" certificate
marked "Created via API" for the archive. If **Certificates** reports a
limit, revoke the old ones.

### 9. TestFlight

After the first upload: **Apps → FTW → TestFlight**.

1. **Additional → Test Information**, for each language:
   - Beta App Description: the first paragraph of `store/<lang>/description.txt`.
   - Feedback Email: an inbox someone reads (see the decision in step 4).
   - Marketing URL and Privacy Policy URL: from `store/<lang>/`.
   - Beta App Review Information: contact, "Sign-in required" off, and
     `store/review-notes.txt` as notes.
2. **Internal Testing → (+)**: group `Sourceful`. Add App Store Connect
   users (up to 100) and turn on automatic distribution.
3. **External Testing → (+)**: group `Beta`. Add the build, then **Submit
   for Review**. Apple reviews the first build; later builds of the same
   version usually go out at once. Invite by email or turn on a public link
   (Open to Anyone, or Filter by Criteria, with a tester limit). Up to
   10,000 testers.
4. For each build, **What to Test**: `store/<lang>/release-notes.txt`.

A build expires after 90 days.

### 10. The App Store version

**Apps → FTW → App Store → iOS App → the version**

| Field | Source |
|---|---|
| iPhone screenshots | `scripts/store-screenshots.sh` (6.9", 1320 × 2868) |
| Promotional Text | `store/<lang>/promotional-text.txt` |
| Description | `store/<lang>/description.txt` |
| Keywords | `store/<lang>/keywords.txt` |
| Support URL | `store/<lang>/support-url.txt` |
| Marketing URL | `store/<lang>/marketing-url.txt` |
| What's New | `store/<lang>/release-notes.txt` (not shown for the first version) |
| Build | The one TestFlight tested |
| App Review Information | Sign-in required: off. Contact: name, email, phone with `+46`. Notes: `store/review-notes.txt` |
| Version Release | Manually release this version |

Then **Add for Review → Submit**.

Guideline 2.1(a) allows a demo mode "in lieu of a demo account with prior
approval by Apple". FTW has no login; the demo stands in for the box. The
notes say so. If review asks for a video of a real box, record pairing
and the car view.

`store/check.sh` checks every text against Apple's limits.

## Each release

1. Set `MARKETING_VERSION` in `FTW.xcconfig` to the new version on `main`.
2. Tag that commit and push the tag:

   ```bash
   git tag ios-v1.0.0 && git push origin ios-v1.0.0
   ```

3. Watch the *iOS release* run. When it reports the upload, the build
   appears in TestFlight within minutes to an hour.
4. Write What to Test, then hand the build to the groups in step 9.

## When the upload fails

The run keeps Xcode's export logs as the `export-logs` artifact.

| Message | Cause |
|---|---|
| Cloud signing permission error | The key is not Admin. |
| No profiles for 'energy.ftw.app' | App ID not registered, or no app record yet. |
| Private key not installed for an Apple Development certificate | Old API certificates; revoke them under Certificates. |
| The bundle version must be higher | A build number was used; run again or tag again. |
| Agreement missing or expired | The Account Holder must accept it under Business. |

## Later

- **M3, push:** an APNs key (**Certificates, Identifiers & Profiles → Keys
  → (+) → Apple Push Notification service**). Not before.
- **FTW Cloud:** update the privacy pages, App Privacy, `review-notes.txt`
  and the description before it ships.
- **April 2027:** apps on the iOS 27.1 SDK or later also need iPhone Duo
  screenshots.
