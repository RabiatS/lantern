<div align="center">

# Lantern

**a language model that lives on your phone**

</div>

---

Lantern runs a quantized LLM entirely on the iPhone. There is no server, no API
key and no account. After the weights are downloaded once, the app works in
airplane mode, and the readout on screen shows what that costs: tokens per
second, memory in use, and the thermal state, live, while it writes.

## What it is

- **Fully offline inference** on Apple silicon through MLX Swift, Metal backend,
  unified memory. The only network call the app ever makes is the one-time
  download of public model weights from Hugging Face.
- **A green light before anything downloads.** The app reads the phone's RAM,
  what this process may still allocate, free disk, and whether Metal is present,
  then says per model: go, go with a warning, or not on this phone.
- **A model catalog with tiers.** A 1B model is the default and runs on 4 GB
  phones. 3B is offered with a warning on 6 GB and cleanly on 8 GB. 8B is Pro
  only and always warned. Nothing above 8B, which is a reliable out-of-memory
  kill even on Pro.
- **A memory pressure handler** that decides whether the app survives on a 6 GB
  phone under load: drop the context on a warning, unload the weights on
  critical or in the background, reload on the next send.
- **A benchmark mode** that runs the engine as an instrument: time to first
  token, decode rate, peak memory, and a two minute sustained run sampled every
  ten seconds with the thermal state, written to Files as JSON and CSV.
- **Unlimited use.** Nothing is metered, because nothing leaves the phone.
- **Built for leaving Wi-Fi.** Downloads are Wi-Fi only by default and wait
  for it rather than fail. The main screen says whether the phone is ready to
  go offline. Chats are kept for seven days from their last message, then
  deleted; nothing accumulates.

## Look and feel

Plain San Francisco type, a calm blue accent on cool neutral ground, paper
tones in light mode, and one warm thing on screen: the flame in the mark.
Every colour is an asset with a light and dark appearance. The chat opens with
a "did you know" card, one plain-language fact about how this kind of AI
works, that disappears with the first message. Settings shows what staying on
the phone has saved, with the assumptions behind the energy estimate spelled
out on the "How Lantern works" page.

The same target builds for iPhone, iPad and Mac. On a Mac the model runs on
the same MLX code with far more memory to spare, so every model in the catalog
is offered cleanly.

## Apple Intelligence

On an iPhone 15 Pro or later with Apple Intelligence on, iOS keeps a built-in
model of about 3 billion parameters loaded and shares it between apps. Lantern
treats it as a second engine behind the same interface: pick "Apple
Intelligence" under "Who answers" and the chat, the personas and the guides
run on it, with no download. The quick benchmark runs on whichever engine is
answering, and Settings shows the two side by side.

The two also work together. When Apple's model is available it writes the
summaries that keep long chats going, so the downloaded model keeps its memory
and the phone its time. The welcome screen offers Apple's model as a way to
start immediately and download a Lantern model later.

What Apple's model cannot give you is the point of the Lantern model: you
cannot see its memory, choose its size, read its weights, or run it on a phone
without Apple Intelligence. Its token counts are estimated from characters,
and the app marks them with a tilde.

## Personas

The system prompt is the one place the app has a point of view, so it is a
setting. Beyond "general" the personas are the ones that matter with no
signal: a curious mind for the question you would have searched, a day out
helper for lists and errands, a homework tutor, roadside
helper, first aid guide, outdoors and survival, travel
phrasebook, a calm companion for waiting it out, field notes that turn a
rambling note into a list, and an electronics tutor. Each prompt is under a
hundred words, because a 1B model follows a short brief and every word is
prefilled on every turn. The safety personas open with "call emergency
services", say what serious looks like, and answer from the bundled guides in
`Lantern/Guides` rather than from the model's memory; each reply names the
passages it was given.

## What it is not

- No custom inference engine and no llama.cpp bindings. MLX is faster on Apple
  silicon and the `mlx-swift-lm` package already knows every architecture in
  the catalog.
- No training or fine-tuning on device.
- No cloud fallback. If the model is not on the phone, the app says so.
- No simulator. MLX needs a real GPU; the gate refuses the simulator by name.

## Stack

| | |
| --- | --- |
| Inference | [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) 3.31 (`MLXLLM`, `MLXLMCommon`) on [mlx-swift](https://github.com/ml-explore/mlx-swift) 0.31 |
| Tokenizer | [swift-transformers](https://github.com/huggingface/swift-transformers) 1.3 (`Tokenizers`), bridged by hand in `TransformersTokenizerLoader` so there is no macro build |
| Weights | 4-bit safetensors from [mlx-community](https://huggingface.co/mlx-community), fetched by the app's own downloader with SHA-256 verification |
| UI | SwiftUI, iOS 26, Swift 6.2 |

Note that the LLM libraries moved out of `mlx-swift-examples` into
`mlx-swift-lm` in 2025. The examples repo now only holds sample apps.

## Building

Open `Lantern.xcodeproj` in Xcode 26 and run on a physical iPhone, or pick
"My Mac" as the destination to run it on the Mac. The first
build compiles MLX's C++ and Metal kernels, which takes several minutes. Xcode
will ask once to trust the `CudaBuild` plugin that ships inside `mlx-swift`;
from the command line the equivalent is:

```bash
xcodebuild build -project Lantern.xcodeproj -scheme Lantern -destination 'generic/platform=iOS' -skipPackagePluginValidation -skipMacroValidation
```

Unit tests do not touch MLX and run in the simulator:

```bash
xcodebuild test -project Lantern.xcodeproj -scheme Lantern -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -skipMacroValidation
```

The one entitlement in `Lantern.entitlements`, increased memory limit, is
required for the memory numbers to mean anything. It is an ordinary capability
that automatic signing registers and it works on a free Personal Team. Extended
virtual addressing is left out on purpose: Personal Teams cannot sign it and
nothing here needs it.

## Why this exists

This is a learning project: figure out how on-device ML actually behaves with
MLX on a phone, with real numbers, so that the next prototype starts from
knowledge instead of guesses. The notes below grow as the project does.

## Learnings so far

- The LLM libraries live in `mlx-swift-lm` now, not `mlx-swift-examples`. The
  tokenizer and downloader are separate packages you bring yourself.
- MLX does not run in the iOS Simulator. Plan on a real phone from day one and
  keep unit tests free of MLX so they can still run on the Mac.
- The memory ceiling is not RAM. With the increased memory limit entitlement, a
  12 GB iPhone 17 Pro still gives the app about 6 GB. Read
  `os_proc_available_memory()` and believe it.
- Weights are half the story. The KV cache costs
  layers x kv_heads x head_dim x 4 bytes per token of context, and a model
  without grouped-query attention (Phi 3.5 mini) pays three times more than
  one with it (Llama 3B).
- A 1B model at 4-bit is genuinely fast: 80 to 85 tokens per second and 60 ms to
  first token on an iPhone 17 Pro, in 0.7 GB.
- Qwen 2.5 1.5B answers noticeably better than Llama 3.2 1B for 170 MB more on
  disk and the same speed class. Newer training data matters more than
  parameter count at this size.
- Small models loop, invent, and forget. Treat them as a writing and explaining
  partner, not a reference, and keep the context window bounded.
- SwiftUI cannot draw 80 tokens a second. Batch text updates to about 20 a
  second and make the streaming row the only view that redraws.
- Swift 6.2 concurrency shape that worked: an actor owns the model and its
  session, pure core types are `nonisolated`, heavy work is `@concurrent` so it
  leaves the main actor.
- A 1B model's own memory of first aid is not something to hand a person in
  trouble. Retrieval over a few pages of reviewed text, with BM25 plus Apple's
  on-device sentence embedding, fixes that without any extra download, and the
  reply can say which passage it came from.
- Serialise requests to the model; never refuse them. Every "busy" error in an
  early build was a tap that landed while something else was generating.
- A free Personal Team can sign the increased memory limit but not extended
  virtual addressing. Nothing here needs the latter.
- Xcode asks once to trust the build plugin inside `mlx-swift`. From the
  command line pass `-skipPackagePluginValidation`.
- The simulator has no MLX Metal device, and merely touching MLX's allocator
  aborts there. Guard every MLX call behind "is a model loaded", which also
  spares a phone a needless MLX start at launch.
- A composer placed as a safe-area inset can end up under the keyboard on a
  real phone. A plain vertical stack, transcript over composer, does not.

## What a model this size can do on a phone

Things a 1B to 3B model handles well enough to build on, all offline:

- Summarise or rewrite text the user already has: notes, messages, a pasted
  article, a voice memo transcript from the Speech framework.
- Draft and adjust tone: a reply, a caption, a shorter version of a paragraph.
- Explain and tutor within a subject the system prompt sets, like the
  electronics persona here.
- Pull structure out of text: dates, amounts, names, a to-do list from a
  rambling note.
- Classify and tag: is this message urgent, which folder does this photo
  caption belong in, what language is this.
- Answer questions over text you hand it in the prompt. Retrieval over the
  user's own documents is the natural next layer.

Things it is not for: current facts, long documents beyond the context window,
anything where a wrong answer costs more than a retry.

## Layout

```
Lantern/
  App/            entry point and a bare working screen (real UI comes last)
  Core/
    Catalog/      the static model list with tiers and KV cost per token
    Device/       the green light: tier, verdict, live memory readings
    Store/        Hugging Face manifest, resumable downloads, SHA-256, install records
    Tokenizer/    swift-transformers bridged to MLXLMCommon.Tokenizer
    Inference/    the engine actor: load, unload, stream, one-off generation
    Memory/       UIKit memory warnings and the kernel pressure source
    Benchmark/    quick and sustained runs, JSON and CSV output
    AppState      the coordinator the UI talks to
  Model/          conversation and message types
  Persistence/    one JSON file per conversation
LanternTests/     device gate, catalog, hub parsing, checksums, persistence, CSV
```

See `ARCHITECTURE.md` for the memory math and the decisions behind it.
