# App Privacy answers for App Store Connect

The whole story is one sentence: Lantern collects no data. These are the
answers to give in App Store Connect, App Privacy.

## Data collection

"Do you or your third-party partners collect data from this app?"
**No, we do not collect data from this app.**

That is the entire questionnaire. Do not select any data type. The nutrition
label will read "Data Not Collected".

## Why that is the truthful answer

- No account, no sign-in, no identifiers generated or stored.
- No analytics, crash reporting, advertising or third-party SDKs of any kind.
- Chats, photos and drawings are stored only on the device and deleted with
  the chat or after seven days. They are never transmitted.
- The app makes exactly one kind of network request: downloading model files
  from huggingface.co over HTTPS, at the user's request. Like any download,
  Hugging Face's servers receive the request; the app sends no identifier,
  no token and no user content with it. Apple's definition of "collected"
  covers data transmitted off the device by the developer or partners in a
  way that can be used; a plain file download does not qualify.
- Benchmark and diagnostic files are written to the app's own Documents
  folder on the device, visible in the Files app, and go nowhere.

## Privacy manifest

`Lantern/PrivacyInfo.xcprivacy` declares: no tracking, no tracking domains,
no collected data types, and three required-reason APIs with their reasons
(UserDefaults CA92.1, file timestamps C617.1, disk space E4A2.1).

## Privacy policy URL

https://rabiats.github.io/lantern-site/privacy
