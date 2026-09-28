# App Store kit

Everything App Store Connect asks for, ready to paste.

| File | Use |
| --- | --- |
| `names.md` | Three name and subtitle pairs, checked against the store |
| `listing.md` | Promotional text, description, keywords, categories, URLs |
| `review-notes.md` | Notes for App Review: no account, how to try each feature |
| `privacy-answers.md` | App Privacy answers: data not collected, and why that is true |
| `age-rating.md` | Questionnaire answers and the reasoning for 17+ |
| `featuring.md` | Editorial pitch |
| `screenshots/` | 6.9 inch screenshots, 1320 by 2868, light and dark |

Support and privacy pages are hosted from the public `lantern-site` repository
at https://rabiats.github.io/lantern-site/.

Build and upload: `scripts/testflight.sh`. Register the phone first with
`scripts/register-device.sh <udid>`.
