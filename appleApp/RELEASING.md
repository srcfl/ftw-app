# Releasing the iPhone app

This Mac tests, archives, signs and uploads, with one script
([`scripts/release.sh`](scripts/release.sh)); no GitHub runner builds a
release (Fredrik, 28 October 2026). A person sets up App Store Connect once,
then runs the script for each release. This file lists that person's steps in order:
first the shortest way onto your own iPhone, then what external testers
and the App Store need. Checked against Apple's pages on 12 October 2026;
Apple moves menus, so trust the screen if it differs.

| What | Value |
|---|---|
| Seller | Sourceful Labs AB (reg. no. 559382-0458), Kalmar, Sweden |
| Team ID | `L66M368PZ6` |
| Bundle IDs | `energy.ftw.app` (registered), `energy.ftw.app.widgets`, `energy.ftw.app.notify`, `energy.ftw.app.watchkitapp`, `energy.ftw.app.watchkitapp.widgets` |
| App Group | `group.energy.ftw.app` |
| Release | [`scripts/release.sh`](scripts/release.sh), on this Mac |
| Store texts | [`store/`](store/) |
| Privacy and support | `https://ftw.sourceful.energy/privacy`, `https://ftw.sourceful.energy/support` ([srcfl/ftw-web](https://github.com/srcfl/ftw-web)) |

## How a build travels

1. `scripts/release.sh` runs on a clean checkout of a commit on
   `origin/main`, and refuses anything else: the store build must come from
   published source ([Encryption and export](#5-encryption-and-export)). It
   ships `MARKETING_VERSION` from `FTW.xcconfig`. The build number is the
   date and time, `20261028.1342`, so each upload is higher than the last
   without asking Apple.
2. It runs `swift test`, then archives with this Mac's Xcode and checks the
   version in the app, its extensions and the watch app.
3. Xcode exports with [`ExportOptions.plist`](ExportOptions.plist)
   (`app-store-connect`, `upload`) and sends the build to App Store Connect.
   It shows in TestFlight once Apple has processed it.
4. With the App Store Connect key on this Mac, the script then gives the
   build to the public beta: it waits for processing, writes What to Test,
   adds the build to `Pilot` and submits it for Beta App Review
   ([`scripts/testflight-pilot.py`](scripts/testflight-pilot.py)). Without
   the key it says so, and **Actions → iOS public beta** does the same from
   GitHub, where the key lives as secrets; that workflow builds nothing.

### Signing on this Mac

A release never makes a certificate. The archive is signed with the team's
**Apple Development** certificate in the login keychain (Fredrik Ahlgren,
team `L66M368PZ6`, until 12 October 2027) and the profiles Xcode already
holds, and it runs without `-allowProvisioningUpdates`, so Xcode cannot
create one. The export signs for the App Store with Apple's cloud-managed
distribution certificate, which lives with Apple, through the App Store
Connect key or else the account signed in under **Xcode → Settings →
Accounts**.

The GitHub release workflow did the opposite: every run on a clean runner
made a new "Apple Development" certificate through the API key, until the
team reached Apple's limit on 28 October 2026 ("Your account has reached
the maximum number of certificates"). That workflow is gone. The ones it
made, marked "Created via API" under **Certificates**, can be revoked; the
certificate above is not one of them.

If the certificate is ever lost, restore it from a backup of the login
keychain, or make one new certificate in Xcode once and keep it; never one
per release.

### The App Store Connect key on this Mac

For the public beta step, and to upload without the Xcode account:

1. Put the `.p8` at `~/.appstoreconnect/private_keys/AuthKey_<KEY ID>.p8`
   (`chmod 600`), where `altool` also looks.
2. Put its ids, which are not secret, in `~/.appstoreconnect/ftw.env`:

   ```bash
   ASC_KEY_ID=XXXXXXXXXX
   ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000
   ```

An App Manager key is enough for TestFlight; signing with the key in place
of the Xcode account needs Admin.

Apple has required the iOS 26 SDK for uploads since 28 April 2026 and
requires the iOS 27 SDK from April 2027. Xcode 27 meets both.

## Your own iPhone, from Xcode

No App Store Connect, no key. The app is signed for development and runs
until the profile expires.

1. On the iPhone, connect it to the Mac once, then **Settings → Privacy &
   Security → Developer Mode → On**. The iPhone restarts; confirm.
2. In Xcode: **Settings → Accounts → (+) → Apple Account**, and sign in
   with an Apple Account in team `L66M368PZ6`.
3. Unlock the iPhone and tap **Trust** when it asks.

The simplest way: open `appleApp/FTW.xcodeproj`, pick the iPhone above the
editor, press **⌘R**. From the command line instead, find the iPhone's
UDID. Run these from the repository's root:

```bash
xcrun devicectl list devices
```

Build for it. Automatic signing registers the iPhone and the widget's App
ID in the team:

```bash
xcodebuild build -project appleApp/FTW.xcodeproj -scheme FTW -configuration Debug -destination 'platform=iOS,id=<UDID>' -derivedDataPath appleApp/build/device -allowProvisioningUpdates
```

Install and open it:

```bash
xcrun devicectl device install app --device <UDID> appleApp/build/device/Build/Products/Debug-iphoneos/FTW.app
```

```bash
xcrun devicectl device process launch --device <UDID> energy.ftw.app
```

## Internal TestFlight, the shortest way

Internal testers are people in the App Store Connect team, up to 100.
Their builds need no Beta App Review.

### 1. Accept the agreement

The Account Holder accepts the latest Apple Developer Program License
Agreement under **Business**. Until then App Store Connect refuses new
apps, and the API key stops working. A free app needs no Paid Apps
Agreement.

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
shows English. Swedish comes later, under the localization menu in App
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

### 3. Make the API key and add the secrets

**Users and Access → Integrations → App Store Connect API → Team Keys →
Generate API Key**

- Name: `GitHub ftw-app release`.
- Access: **Admin**. With an App Manager key, cloud signing fails
  ("Cloud signing permission error"; [Apple forum
  thread](https://developer.apple.com/forums/thread/698117)). The reason:
  the runner has no certificate, so the export signs with a cloud-managed
  distribution certificate. Apple's [roles
  table](https://developer.apple.com/support/roles/) gives those to Account
  Holder and Admin; other roles need a per-user permission, and a team key
  cannot carry one. Role and name cannot change after creation.
- Download the `.p8` file. Apple offers it once.
- The Key ID is in the key's row; the Issuer ID is at the top of the page.

`ASC_KEY_ID` and `ASC_ISSUER_ID` are plain text; `gh` asks for each.
`ASC_KEY_P8` is the `.p8` file's PEM text as it is, not base64:

```bash
gh secret set ASC_KEY_ID --repo srcfl/ftw-app
```

```bash
gh secret set ASC_ISSUER_ID --repo srcfl/ftw-app
```

```bash
gh secret set ASC_KEY_P8 --repo srcfl/ftw-app < AuthKey_XXXXXXXXXX.p8
```

Then delete the `.p8` from your disk, or keep it in a password manager.

**Safer, when there is time.** An Admin key can do much more than upload
builds, and any branch's workflow can read a repository secret. The job
also reads secrets from an environment `app-store`:

1. **srcfl/ftw-app → Settings → Environments → New environment →
   `app-store`.**
2. **Deployment branches and tags → Selected branches and tags**: add
   branch `main` and tag `ios-v*`. Optionally add yourself as a required
   reviewer.
3. Set the same three secrets with `--env app-store` added, then delete
   the repository ones.

### 4. Release a build

On a clean checkout of `main`:

```bash
appleApp/scripts/release.sh
```

It never makes a certificate ([Signing on this Mac](#signing-on-this-mac)).

### 5. Answer the encryption question, if asked

The store-ready branch ([#13](https://github.com/srcfl/ftw-app/pull/13))
sets `ITSAppUsesNonExemptEncryption` to `NO`, so builds that carry it skip
this. If a build shows **Missing Compliance** in TestFlight, click
**Manage** next to it and choose **None of the algorithms mentioned
above** ([Encryption and export](#5-encryption-and-export) says why).

### 6. Add yourself as a tester

**Apps → FTW → TestFlight → Internal Testing → (+)**: group `Sourceful`.
Add yourself and others from the App Store Connect team, and turn on
automatic distribution so each new build reaches the group. On the iPhone,
install TestFlight from the App Store, signed in with the same Apple
Account, and accept the invitation.

A build expires after 90 days.

## Before external testers and the App Store

### 1. Links

- `https://app.ftw.energy/.well-known/apple-app-site-association` must
  answer before review: passkeys and pairing links need it
  ([srcfl/ftw-webapp#77](https://github.com/srcfl/ftw-webapp/pull/77)).
  On 12 October 2026 it answered 404.
- `ftw.energy` must serve the website. On 12 October 2026 it had no
  address record, and the Cloudflare Pages project `ftw` served only
  `ftw.sourceful.energy`. In Cloudflare: **Workers & Pages → ftw → Custom
  domains → Set up a custom domain → `ftw.energy`**. Then check:

  ```bash
  curl -sI https://ftw.sourceful.energy/privacy
  ```

  If `ftw.energy` stays off, replace it with `ftw.sourceful.energy` in
  `store/*/privacy-url.txt`, `support-url.txt` and `marketing-url.txt`.

### 2. App Information

**Apps → FTW → App Information** (under General), for each language. Add
**Swedish** from the localization menu first.

| Field | Value |
|---|---|
| Subtitle | `store/<lang>/subtitle.txt` |
| Category | Primary **Utilities**, no secondary. Not Health & Fitness: that asks for a medical device declaration. |
| Content Rights | No third-party content: the app shows only the user's own box. |
| Age Rating | **Set Up Age Ratings**. Answer No to every capability (web access, user-generated content, social media, messaging, advertising) and None to every content item. Age Categories and Override: Not Applicable. Result: 4+. |
| Copyright | `2026 Sourceful Labs AB` |
| Privacy Policy URL (App Privacy) | `store/<lang>/privacy-url.txt` |

### 3. Trader status under the EU Digital Services Act

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

### 4. App Privacy

The old M1 answer, “Data Not Collected”, does not cover FTW Cloud.
Cloud holds a readable home copy, home and phone identifiers and push tokens.
The versioned statistics scope adds rounded energy and configured capacities.
Collection of those hourly reports still waits for the signed privacy review.

Prepare **Apps → FTW → App Privacy** with this mapping:

| Type | Use | Linked | Tracking |
|---|---|---|---|
| User ID | Home and statistics ids: App Functionality and Analytics | Yes | No |
| Device ID | Phone keys and push tokens: App Functionality | Yes | No |
| Other Data Types | Home readings, plans and configuration: App Functionality; project statistics: Analytics | Yes | No |

Pseudonymous home ids still link records. No advertising or data broker receives
them. Local encrypted sessions and the on-phone demo do not add a server copy.
The app's privacy manifest declares the same categories. Extensions keep their
own declarations: reading an App Group cache alone is not collection.

Before publishing, compare the actual shipped Cloud fields with this table,
check the Swedish and English privacy pages, and preview Apple's label.
**Publish** includes a legal attestation; the responsible person must approve
that final step. Record its date and a screenshot with the statistics DPIA.
A code change or upload does not update App Store Connect's answers.

Sources checked 17 October 2026: [Apple's definitions](https://developer.apple.com/app-store/app-privacy-details/),
[App Privacy steps](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
and [manifest fields](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes).

### 5. Encryption and export

#13 sets `ITSAppUsesNonExemptEncryption` to `NO` in `FTW-Info.plist`, so
App Store Connect asks nothing per build. A build without it asks under
**App Information → App Encryption Documentation (+)**, or **Manage** next
to the build in TestFlight; answer **None of the algorithms mentioned
above**.

Why: all cryptography runs in CryptoKit, which ships with iOS (X25519,
ChaCha20-Poly1305, SHA-256 and HKDF, AES-GCM, Ed25519). The app implements
no algorithm itself; Noise IK is a published protocol built on those.
Apple's table says encryption "limited to that within the Apple operating
system" needs no documentation. No Apple page says outright that CryptoKit
counts; that is our reading.

The rest is #13's reading, which no lawyer has reviewed; its sources are in
the PR.

- **United States.** The source is public, so the encryption is not
  subject to the EAR (15 CFR 742.15(b) and the note to 734.3(b)(2)–(3)): no
  email to BIS and the NSA, and no year-end report. That holds only if every
  store build comes from a published commit. The workflow passes
  `FTW_SOURCE_REVISION=$GITHUB_SHA`; tag only commits pushed to this
  public repository.
- **France.** Apple asks for nothing with "None". French law (Décret
  2007-663, art. 3–5) still requires a free declaration to ANSSI one month
  before the app is offered in France. Fredrik decided on 12 October 2026
  that France waits: the first release leaves it out, and the declaration
  comes later ([Before launching in France](#before-launching-in-france)).

### 6. Price and countries

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
4. Remove **France** until the ANSSI declaration is filed and a month has
   passed ([Before launching in France](#before-launching-in-france)).
5. Untick **Apple silicon Mac** and **Apple Vision Pro**. Apple publishes
   iPhone apps there by default; M1 is iPhone only.

Other countries, checked for a free 4+ utility that is not a game:

| Where | Rule | For FTW |
|---|---|---|
| South Korea, Vietnam | Game ratings and licences | Games only. Nothing to do. |
| Brazil | Tax forms | Only for developers in Brazil. |
| Australia, Brazil, Singapore | 18+ download checks | Not for a 4+ app. |
| Texas, Utah, Louisiana | Age assurance for new accounts (Declared Age Range API) | **Decide with counsel.** M1 has no accounts and no age-dependent content. |
| France | ANSSI encryption declaration one month ahead (#13's reading) | Left out of the first release (step 4). |
| Russia | — | "Sourceful Energy" is not in the Russian store. **Decide** whether FTW follows. |

### 7. External TestFlight

**Apps → FTW → TestFlight**

1. **Additional → Test Information**, for each language:
   - Beta App Description: the first paragraph of `store/<lang>/description.txt`.
   - Feedback Email: an inbox someone reads (see the decision in step 3).
   - Marketing URL and Privacy Policy URL: from `store/<lang>/`.
   - Beta App Review Information: contact, "Sign-in required" off, and
     `store/review-notes.txt` as notes.
2. **External Testing → (+)**: group `Pilot`, which has the public link. An internal group must exist
   first. Add the build, then **Submit for Review**. Apple reviews the
   first build; later builds of the same version usually go out at once.
   Invite by email or turn on a public link (Open to Anyone, or Filter by
   Criteria, with a tester limit). Up to 10,000 testers.
3. For each build, **What to Test**: `store/<lang>/release-notes.txt`.
   The *iOS public beta* workflow writes it and does steps 2 and 3 for the
   group `Pilot` ([Each release](#each-release)).

### 8. The App Store version

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

1. Set `MARKETING_VERSION` in `FTW.xcconfig` to the new version and lead
   `store/<lang>/release-notes.txt` with what is new, in a pull request.
   Merge it once it is green on this Mac (`swift test`, a simulator build).
2. On a clean checkout of that `main`:

   ```bash
   appleApp/scripts/release.sh
   ```

   `FTW_SKIP_TESTS=1` skips `swift test` when it just ran;
   `FTW_SKIP_PILOT=1` uploads without the public beta step.
3. Internal testers get the build once Apple has processed it, usually
   within the hour. With the key on this Mac the script has already given
   it to `Pilot` and submitted it for Beta App Review; without it, run
   **Actions → iOS public beta** with the version and build it printed.

## When the upload fails

Xcode's export logs are in the folder the export names, under `$TMPDIR`,
and the archive stays in `appleApp/build/release/<version>-<build>/`.

| Message | Cause |
|---|---|
| Cloud signing permission error | The key is not Admin. |
| No profiles for 'energy.ftw.app' | App ID not registered, or no app record yet. |
| Private key not installed for an Apple Development certificate | This Mac lacks the certificate's private key; restore it ([Signing on this Mac](#signing-on-this-mac)). |
| Your account has reached the maximum number of certificates | Something asked for a new certificate; find it and stop it, then revoke the "Created via API" ones. |
| The bundle version must be higher | A build number was used; run again a minute later. |
| Agreement missing or expired | The Account Holder must accept it under Business. |
| Xcode upload failed, then altool succeeded | Nothing to do; Apple got the build. |
| The upload succeeded but no build appears in TestFlight | Apple refused it after upload. `GET /v1/apps/{id}/buildUploads` gives the reason. |
| ITMS-90626 Invalid Siri Support | An App Intent's title or description names Apple's products, such as "iPhone". Say "phone" instead. |

## Before launching in France

French law asks the supplier of an encryption product to declare it to
ANSSI, France's cybersecurity agency, one month before offering it there
(#13's reading of Décret 2007-663; no lawyer has reviewed it). The
declaration is free.

1. Take the declaration form (Annex I of the decree) from ANSSI's [forms
   page](https://cyber.gouv.fr/reglementation/reglementation-identite-confiance-numerique/controles-reglementaires-cryptographie/controle-moyen-de-cryptologie/controle-reglementaire-cryptographie-formulaires/).
   [Contrôle relatif à un moyen de
   cryptologie](https://cyber.gouv.fr/reglementation/reglementation-identite-confiance-numerique/controles-reglementaires-cryptographie/controle-moyen-de-cryptologie/)
   explains what to send. Describe the app's cryptography as in
   [Encryption and export](#5-encryption-and-export). ANSSI asks the
   supplier to request a "grand public" (consumer) classification in the
   same declaration.
2. Send it to ANSSI as those pages describe, and keep the receipt.
3. A month after filing: **Pricing and Availability → App Availability →
   add France**.

## Later

- **M3, push:** an APNs key (**Certificates, Identifiers & Profiles → Keys
  → (+) → Apple Push Notification service**). Not before.
- **FTW Cloud:** keep privacy pages, App Privacy, the manifest,
  `review-notes.txt` and the description in step when its data use changes.
  The October 2026 declaration includes project statistics; it does not
  enable hourly collection or replace the signed C8 review.
- **April 2027:** apps on the iOS 27.1 SDK or later also need iPhone Duo
  screenshots.
