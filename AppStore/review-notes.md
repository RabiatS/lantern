# Notes for App Review

There is no account and nothing to sign into. Every feature is reachable from
a fresh install.

How to try it:

1. On first launch, pick "Llama 3.2 1B" (663 MB) and tap Download. It needs
   Wi-Fi by default; a toggle in Settings allows cellular. The download is
   verified against the publisher's checksums.
2. Tap Start. Type anything, or tap the example prompt. Replies stream in
   under a second on a recent iPhone.
3. Turn on airplane mode and send another message. Nothing changes: no
   network is used after the download.
4. The persona picker (title at the top) switches the assistant's role. First
   aid, roadside and outdoors answer from guides built into the app and show
   which passage they used under each reply.
5. Settings (sliders icon) shows the device readout, the models, a benchmark,
   and "How Lantern works, in plain words".

Optional features that need a larger download:

- Photos: download "SmolVLM 500M" or "Qwen2-VL 2B" under Models, then use
  the camera button in the composer.
- Drawing: download the picture maker under "Drawing pictures" (2.6 GB), type
  a description, then choose "Draw a picture from this text" from the camera
  button. This needs an iPhone with 6 GB of memory or more.

Camera and photo library permissions are requested only when the camera
button is used, to attach a picture for the on-device model. Pictures never
leave the device.

The models are open weights published by their authors (Meta, Alibaba,
Microsoft, HuggingFace, Stability AI) and converted for Apple silicon by the
MLX community. The app downloads them from huggingface.co over HTTPS. That is
the app's only network use. Lantern does not run in the iOS Simulator because
the inference library needs a physical GPU; please review on a device.

The app collects no data, has no analytics and no third-party SDKs. Chats are
stored on the device for seven days and then deleted.

Contact for review questions: rabiat.dev@gmail.com
