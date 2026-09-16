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

Open `Lantern.xcodeproj` in Xcode 26 and run on a physical iPhone. The first
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
