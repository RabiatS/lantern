# Architecture

The point of this app is the constraint. A phone has one pool of memory shared
by the CPU, the GPU and every other app, a kernel that kills the foreground app
the moment it crosses a line it never tells you about, and a thermal envelope
that starts throttling a sustained workload within a minute or two. Everything
below is about making that constraint measurable instead of mysterious.

## The memory math

### What the phone gives an app

iOS does not let a foreground app use all of RAM. Jetsam enforces a per-process
limit that is a fraction of physical memory; crossing it is an immediate kill
with no exception to catch. The `com.apple.developer.kernel.increased-memory-limit`
entitlement raises that line. The app reads the live value through
`os_proc_available_memory()`, which is exactly the number jetsam enforces, and
that reading is what the green light uses. The ceilings the tests assume, with
the entitlement in place, are roughly:

| Phone RAM | Reads as | Tier | App may use (approx.) |
| --- | --- | --- | --- |
| 4 GB (iPhone 12, 13, SE 3) | 3.7 GiB | compact | 2.5 GB |
| 6 GB (iPhone 14, 15, 16e) | 5.6 GiB | standard | 4.2 GB |
| 8 GB (15 Pro, all 16 and 17) | 7.5 GiB | pro | 6 GB |

These are starting assumptions. The first job on a real device is to run the
benchmark and replace them with measurements.

### What a model costs

Three parts: weights, KV cache, scratch.

**Weights** are the safetensors size. 4-bit quantization puts a 3B model at
about 1.8 GB and an 8B at 4.5 GB. Sizes in the catalog are the exact byte
counts from the Hugging Face manifests.

**KV cache** is the part people forget, and it scales with context length. Per
token of context, in fp16:

```
bytes/token = layers x kv_heads x head_dim x 2 (K and V) x 2 (bytes)
```

| Model | layers | kv heads | head dim | bytes/token | 4096 tokens |
| --- | --- | --- | --- | --- | --- |
| Llama 3.2 1B | 16 | 8 | 64 | 32 KB | 128 MB |
| Qwen 2.5 1.5B | 28 | 2 | 128 | 28 KB | 112 MB |
| Llama 3.2 3B | 28 | 8 | 128 | 112 KB | 448 MB |
| Phi 3.5 mini | 32 | 32 | 96 | 384 KB | 1.5 GB |
| Llama 3.1 8B | 32 | 8 | 128 | 128 KB | 512 MB |

Phi 3.5 mini has no grouped-query attention, so its cache is three and a half
times Llama 3B's per token. That single row is why Phi is Pro-only and always
warned in the catalog even though it is marketed as "mini": with the Pro
tier's 8192 token window it wants 3 GB of cache on top of 2.1 GB of weights,
the same working set as the 8B.

**Scratch** is MLX's buffer pool, activations during prefill, the tokenizer's
vocabulary tables, SwiftUI and the app heap. Budgeted at 600 MB and capped
where it can be: the MLX cache limit is set to 64 MB at load so the pool cannot
grow into the space the KV cache needs.

### Where it breaks

Put together, with the KV window the engine actually allows per tier:

| Model | compact (2048 tok) | standard (4096 tok) | pro (8192 tok) |
| --- | --- | --- | --- |
| Llama 3.2 1B | 1.4 GB, go | 1.5 GB, go | 1.6 GB, go |
| Qwen 2.5 1.5B | 1.6 GB, go | 1.6 GB, go | 1.7 GB, go |
| Llama 3.2 3B | refused | 2.9 GB, warned | 3.4 GB, go |
| Phi 3.5 mini | refused | refused | 6.0 GB, warned |
| Llama 3.1 8B | refused | refused | 6.2 GB, warned |

The earlier plan had 3B as the default across every tier. On a 6 GB phone that
leaves about 1.3 GB between the estimate and the kill line, before the user
opens Safari. It runs, and people do run it, but it is not a default. So the
default is the 1B, 3B is opt-in with an explicit warning on 6 GB, and the 8B
and Phi are always warned because 6 of 6 is on the line and the estimate only
holds if the user keeps the context short. The catalog encodes this as two tiers per
model: `requiredTier`, below which it is refused, and `comfortableTier`, below
which it is offered with a warning.

## The green light

`DeviceCapability.verdict(for:report:)` runs before any download and again
before any load. It is a pure function of a `DeviceReport`, which is why every
case in it has a unit test with a fake phone. Order of checks:

1. No Metal device, or the simulator: refused. MLX needs a real GPU.
2. Under 3.5 GiB physical: refused, nothing fits.
3. The model's required tier above the phone's tier: refused.
4. Free disk under the download plus ten percent plus a margin: caution.
5. `os_proc_available_memory()` under the estimated peak: caution, with the
   shortfall in gigabytes. This is the "close other apps" case.
6. The model's comfortable tier above the phone's tier: caution, with the
   estimate and the live available figure side by side.
7. Otherwise: go.

## Components

**ModelStore** owns the weights on disk. It reads the repository's commit and
file tree from the hub, refuses gated repositories up front, checks disk, then
downloads each file with a resumable `URLSessionDownloadTask`, verifies the
size and the SHA-256 the hub published for every LFS file, and only then writes
`install.json`. A half-finished folder is never mistaken for an installed
model. Verified files carry a `.verified` sidecar with their checksum so a
launch does not re-hash four gigabytes. Model folders are excluded from backup
and live in Application Support, so they survive updates and never sync.

**TransformersTokenizerLoader** reads the tokenizer from the same folder as
the weights. That is the whole answer to tokenizer and model version mismatch,
which is the most common silent break in on-device LLM apps: both come from one
repository revision, recorded in `install.json`, and there is no way to load
one without the other. The bridge from `Tokenizers.Tokenizer` to
`MLXLMCommon.Tokenizer` is written by hand rather than through the
`MLXHuggingFace` macros, which keeps swift-syntax and the macro plugin out of
the build.

**InferenceEngine** is an actor around a `ModelContainer` and one
`ChatSession`. Load builds a `ResolvedModelConfiguration` pointing at the
local folder and calls the factory directly, so no downloader is involved at
load time. The session keeps the conversation's KV cache between turns, so a
follow-up question does not re-prefill the whole transcript. `stream` yields
tokens as they are sampled and a final event with prefill time, decode rate and
time to first token. `generateOnce` runs against a throwaway session for the
benchmark. Generation parameters come from the tier: the KV window is 2048,
4096 or 8192 tokens through `maxKVSize`, which makes MLX use a rotating cache
so a long chat cannot grow without bound.

**MemoryPressureMonitor** listens to two signals because they mean different
things. `UIApplication.didReceiveMemoryWarningNotification` is the system
asking this app for memory back. The `DispatchSource` memory pressure source
reports device-wide warning and critical levels. Backgrounding is a third
signal: a resident model is the first thing jetsam takes from a background
app. The policy in `AppState`:

| Signal | While streaming | While idle |
| --- | --- | --- |
| Warning | drop KV cache and MLX pool, keep weights, let the reply finish | unload weights |
| Critical | cancel the reply, unload weights | unload weights |
| Background | drop KV cache and MLX pool | same |

Unloading sets a flag the UI can show, and the next send reloads through
`ensureLoaded()`, which is the only load path. Reload is two to five seconds
for a 3B model.

**BenchmarkRunner** produces the numbers the memory math is supposed to
predict. Quick mode runs five short prompts from a cold cache each and records
time to first token, prefill time, decode rate and MLX peak memory. Sustained
mode generates continuously for a set number of minutes and records, every ten
seconds, tokens in the window, the thermal state and memory. That series is the
throttling curve. Output goes to `Documents/Benchmarks` as JSON and CSV, which
the Files app exposes because `UIFileSharingEnabled` is on.

## Concurrency

The app target uses Swift 6.2 with main-actor default isolation. Types in
`Core` that must not be on the main actor are marked `nonisolated`; the engine
is an actor; the store's install routine is a nonisolated static function so
hashing and file moves happen off the main thread while the store itself,
which the UI observes, stays on it. Progress crosses back with a
`Task { @MainActor in }`.

## Open questions

- The ceilings in the tier table are assumptions until the benchmark has run
  on a 6 GB and an 8 GB phone.
- The scratch allowance of 600 MB is a round number. `WiredMemoryUtils.tune`
  in MLXLMCommon can measure it per model; worth doing once the app runs.
- Background downloads (a `URLSessionConfiguration.background` session) would
  let a 4.5 GB fetch finish with the app closed. The current session waits for
  connectivity and resumes, but only while the app is alive.
