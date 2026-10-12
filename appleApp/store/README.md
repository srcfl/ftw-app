# App Store texts

What the App Store page and TestFlight say about FTW, one file per field,
pasted into App Store Connect by hand ([RELEASING.md](../RELEASING.md)).

| File | App Store Connect field | Limit |
|---|---|---|
| `name.txt` | Name | 30 characters |
| `subtitle.txt` | Subtitle | 30 characters |
| `promotional-text.txt` | Promotional Text | 170 characters |
| `description.txt` | Description | 4000 characters |
| `keywords.txt` | Keywords, comma-separated, each three or more characters | 100 bytes |
| `release-notes.txt` | What's New, and What to Test in TestFlight | 4000 characters |
| `privacy-url.txt` | Privacy Policy URL | |
| `support-url.txt` | Support URL | |
| `marketing-url.txt` | Marketing URL | |
| `review-notes.txt` | App Review Information → Notes, one for all languages | 4000 bytes |

`en-US` is the primary language, so countries without their own text show
it. `sv-SE` is Swedish.

Claim only what the app on `main` does. Write plainly: short words, active
voice, no stock phrases, nothing left to cut. Then run:

```bash
appleApp/store/check.sh
```
