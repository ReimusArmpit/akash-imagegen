# Akash image-gen host — prep kit

Target: **RTX 3060 12GB @ $0.06/hr**, Forge-Neo as the UI, plus a model
download panel and FileBrowser. Everything here is prepped so that when a card
frees up you only do: **build → deploy → open URL**.

```
sdl/forge-3060-tunnel.yaml  PRIMARY — tunnel mode, cloudflared URLs, 120 uact/block
sdl/forge-3060.yaml        alt    — direct mode, UI on the provider hostname
Dockerfile                  Forge-Neo image (CUDA 12.8 + torch 2.9.1+cu128)
entrypoint.sh               PID 1: supervises Neo, panel, FileBrowser, Caddy, tunnels
download_panel.py           web UI for picking individual models/LoRAs
Caddyfile                   basic-auth reverse proxy; routes /, /dl, /files
watch-gpus.sh               live availability poller (or offline replay)
build.sh                    build + push + verify anonymous pull
deploy-test.sh              render credentials, create/accept/close a lease
verify.sh                   end-to-end check of everything above
secrets.env                 trial credentials (gitignored, chmod 600)
```

> The old ComfyUI/llama.cpp modes are gone from the default image. The SDLs
> that drove them were removed rather than left in place: they set
> `MODE=comfy`, which this entrypoint no longer implements, so they would
> have booted a Forge image with ComfyUI flags and failed confusingly.
> ComfyUI is still one build flag away — see §1.

---

## 0. The one-paragraph version

`Dockerfile` bakes the software (Neo, torch, extensions, Caddy, FileBrowser,
cloudflared) into one image. `entrypoint.sh` is PID 1 and boots it: it seeds
Forge into `/work` on the root fs, starts the download panel and
FileBrowser on loopback, puts Caddy on the published port with basic auth, and
optionally opens cloudflared tunnels. Nothing is installed at boot — a lease
must not spend GPU minutes running pip.

**Four surfaces, one port:**

| path | what |
|---|---|
| `/` | Forge-Neo UI (`--gradio-auth` + `--api-auth`) |
| `/dl` | model download panel — pick individual models/LoRAs |
| `/dl/diag` | system diagnostics — GPU, disk, memory, processes, log tails |
| `/files` | FileBrowser — browse `/work`, including your models |

---

## 1. Before you touch the marketplace

Two things that cost you real money if skipped:

1. **Build the image first.** `docker build` pulls torch (~2.5 GB) and the
   Neo tree — **8–15 min**. Do not start this while a 1-of-1 GPU sits idle.
2. **Set credentials.** An exposed Akash hostname is world-reachable. The
   entrypoint **refuses to boot** without `NEO_USER`/`NEO_PASS` rather than
   serving an unauthenticated UI.

### Build & push

```sh
./build.sh                                    # docker.io/YOURUSER/akash-imagegen:<tag>
REGISTRY=ghcr.io USER_NS=you ./build.sh      # GHCR
```

`build.sh` prints the pinned `image:` line. **Paste it into the SDL** — Akash
rejects untagged images and `:latest`, and rejects `v1` if you never built it.

Prefer GHCR over Docker Hub: Docker Hub throttles *anonymous pulls* at
100/6h per IP, and a provider's IP is shared, so a busy box can fail to pull
for reasons unrelated to you.

ComfyUI and llama.cpp are **not** in the image. Both were removed rather than
left behind behind build flags:

- **ComfyUI** — unused, and it needs its own venv plus a second torch
  install (~6 GB more) for a node-graph UI Forge already covers.
- **llama.cpp** — unused on this host, and there is **no exec/shell access to
  the container**, so a `llama-server` binary would be unreachable. It would
  also need a GGUF model, and there is no upload path for one: the panel only
  serves the 298 catalogue entries (exactly one of which is a GGUF, and it's
  a Flux text encoder, not a chat model), and FileBrowser can move files but
  cannot fetch them.

If you ever want llama.cpp back, it is cheap now that the base is 24.04:
a 179 MB prebuilt CUDA tarball, no compile. See the comment in the Dockerfile.

---

## 2. Why these versions

| choice | reason |
|---|---|
| **ubuntu24.04 base** | Neo pins `Pillow==13.0.0` and `numpy==2.3.5`, both of which need Python **≥3.11**. Ubuntu 22.04 ships Python 3.10, so `pip install -r requirements.txt` cannot succeed there at all. Ubuntu 24.04 ships Python 3.12, where every Neo pin resolves. Also gives glibc 2.39, which is what the llama.cpp CUDA prebuilts need — should you ever want one back, it's a 179 MB `COPY` instead of a 15-minute CUDA compile. |
| `runtime` tag, not `cudnn-runtime` | The torch 2.9.1+cu128 wheel declares the whole CUDA userspace stack as pip deps (`nvidia-cudnn-cu12==9.10.2.21`, `nvidia-cublas-cu12`, `nvidia-nccl-cu12`, triton, …). The base image's own cudnn/cublas copies are duplicated weight. The base only needs to supply glibc, `ld.so`, and the driver mount point — the driver itself comes from the Akash host. |
| CUDA 12.8 | newest CUDA with torch 2.9.x wheels covering sm_75–sm_90. 13.x dropped Maxwell/Pascal/Volta (sm_50–sm_72) and some cu130 builds are sm_100/sm_120 only — you don't control the host driver on Akash. |
| torch 2.9.1+cu128 | supports T4 (7.5), A100 (8.0), A10G/3060/3090 (8.6), Ada (8.9), H100 (9.0). |
| `TORCH_CUDA_ARCH_LIST="7.5 8.0 8.6 8.9 9.0"` | compile for the cards Akash actually offers. |
| **no xformers** | Neo wraps the import in try/except and falls back to PyTorch native SDPA. xformers wheels pin exact torch versions (0.0.33 → torch==2.9.0) and are the most likely thing to break a build *or* a boot. |
| Forge branch `neo` | `Haoming02/sd-webui-forge-classic`, **not** `lllyasviel/stable-diffusion-webui-forge`. Different codebase, different extension compatibility. |
| Neo's torch default ignored | Neo wants torch 2.14.0+cu130. We bake 2.9.1+cu128; `prepare_environment()` skips its install when torch is already importable, so it keeps ours. |
| **gradio installed BEFORE requirements.txt** | gradio 4.40.0 wants `pillow<11`, Neo pins `Pillow==13.0.0` — they cannot both hold. Upstream Neo installs gradio first and requirements.txt second, so requirements.txt wins. We match that order deliberately: `requirements_met()` reads the pinned version out of requirements.txt, and if Pillow ended up at 10.x it would return False on **every boot** and re-run `pip install -r requirements.txt` while your GPU lease is billing. Pillow 13 also keeps `pillow-heif` (needs ≥11.1) working. |
| `--skip-python-version-check` | Neo prints "tested with 3.13.15 Python" and warns you may see install errors on anything else. On 3.12 the full dependency set resolves cleanly; suppress the banner so real failures aren't buried. |

---

## 3. Watch the marketplace

```sh
./watch-gpus.sh              # one snapshot
./watch-gpus.sh -w           # poll every 60s, terminal bell + notify-send on change
./watch-gpus.sh -m rtx3060,t4,rtx5000,a10g
```

Read **all four** columns, not just `FREE`:

| column | meaning |
|---|---|
| `FREE`/`TOTAL` | free cards across every provider combined |
| `PROV` | how many **providers** have one free |
| `$/hr_min`–`max` | current bid range |
| last line | what $1 actually buys at the cheapest in-stock card |

`PROV` is the column that predicts whether you get a bid. Akash's own AEP-67
design notes document the failure mode directly: you can see plenty of
aggregate availability and still receive **zero bids**, because

- the free cards are spread across providers, none with enough;
- a provider's free cards are fragmented across *nodes* (past 1-GPU requests
  scattered them), and you need them on one node;
- the node has the GPU but no CPU/RAM headroom left.

So a card at `FREE 1 / PROV 1` is a coin flip, and `FREE 2 / PROV 1` is not
twice as safe as it looks.

Dry-run the poller offline any time:

```sh
AKASH_FIXTURE=snapshot.json ./watch-gpus.sh
curl -s https://console-api.akash.network/v1/gpu-prices > snapshot.json
```

---

## 4. Pricing ceiling

Providers bid **per ~6 s block**, in `uact` where 1 uact = 1 µUSD:

```
blocks/hour = 600
ceiling_uact_per_block = USD_per_hour × 1667     # 1e6 / 600
```

Work backwards from the card's **live ask**. The API's `price.min` already *is*
that card's USD/hr, so the conversion is one line:

| card | live $/hr | GPU-only uact/block |
|---|---|---|
| **rtx3060** | **$0.06** | **100** |
| t4 | $0.11–0.16 | 183 |
| a10g / rtx5000 | $0.18 | 300 |
| rtx4090 | $0.36 | 600 |

Both SDLs ship **120 uact/block ≈ $0.072/hr** — 20% over the current $0.06 ask.
Enough to keep bidding on a slow day, tight enough that a provider can't
quietly bid multiples of the ask and have you accept it unawares.

> **Correction:** an earlier draft shipped `600 uact/block` (~$0.36/hr) as the
> "default". 600 is the *RTX 4090's* price — 6× the 3060's. It would still have
> worked (the ceiling is a max, not a price) but it removes the only guard
> against overbidding. Set the ceiling from the card you're actually hunting.

**The ceiling is a maximum, not a price.** You are billed the *accepted bid*, so
headroom costs nothing extra — but too low a ceiling silently returns zero bids,
which looks identical to "the GPU isn't available" and will waste an evening.

> One inconsistency worth knowing: the GPU pricing API also returns a
> `priceUakt` field whose values do **not** reconcile with `price.min` (USD) at
> 600 blocks/hour — e.g. `a10g` reports `$0.18/hr` and `priceUakt.min
> 275526.63`, which at 6 s blocks would be ~$165/hr. Derived USD figures from
> `priceUakt` are unreliable. **Cost from `price.min`; set the ceiling from the
> formula above.** `watch-gpus.sh` uses `price.min` only.

---

## 5. Deploy

Credentials live in `secrets.env` (gitignored, chmod 600), never in the SDL.
`deploy-test.sh` renders them into a private copy at deploy time — Akash does
**not** expand env vars in an SDL, so editing `secrets.env` alone would leave
`CHANGEME_at_deploy` baked into the manifest.

```sh
./deploy-test.sh preflight    # checks only, no spend
./deploy-test.sh create       # create deployment, print dseq
./deploy-test.sh bids <dseq>
./deploy-test.sh accept <dseq> <provider>
./deploy-test.sh status <dseq>
./deploy-test.sh list         # what is billing right now
./deploy-test.sh close <dseq>  # stop billing, then verify it stopped
./deploy-test.sh panic        # close EVERY active deployment
```

`preflight` checks the CLI, the wallet balance (>5 AKT for escrow+fees), that
the image is tagged, that there is a `global: true` endpoint, and that the SDL
renders without leftover placeholders.

### Stopping the meter

You do not need to remember the dseq. `./deploy-test.sh panic` lists every
`active`/`open` deployment for the key and closes each one — that is the
two-seconds-after-you-realise path. `list` alone is a read-only check.

`close` deliberately does **not** trust the transaction. A `tx deployment
close` can broadcast successfully and still leave the deployment open (wrong
dseq, gas too low to be included, node lagging), and the exit code alone will
not tell you. After closing it polls the chain for up to ~20s until the
deployment reports `closed`, and if it never does it exits non-zero and tells
you billing may still be running. A kill switch that reports success without
checking is worse than none.

### Which SDL

- **`forge-3060-tunnel.yaml`** (default) — `MODE=tunnel`. Neo and FileBrowser
  stay on loopback and cloudflared publishes them. The URL changes every
  redeploy, which is fine for a throwaway trial. The published Akash port
  still exists (Akash rejects a manifest with zero global services) but
  carries nothing but the authenticated proxy.
- **`forge-3060.yaml`** — `MODE=direct`. The UI is on the provider's own
  hostname (`https://<provider>.akashnet.net`). Stable URL, but world-reachable.

In both cases the published port is 8080→80 and everything behind it is behind
basic auth.

---

## 6. The download panel

`download_extras.py` in the AnimeStaples repo is an **interactive menu** —
`input()` calls. In a container there is no TTY, so it raises `EOFError`
immediately. `download_panel.py` serves the same `models.json` catalogue
(298 items) over HTTP instead:

- browse by category or type, search by name
- one **Get** button per item — you pick the one or two you want, not a whole
  category
- live progress (%, bytes) while downloading
- **Delete** to reclaim space
- a **disk quota** (`PANEL_QUOTA_GB`, default 28 GB) so a 9.5 GB Flux
  checkpoint can't fill the volume and take the UI down with it

Downloads use `aria2c` (8 connections, resumable) and fall back to `curl`
automatically if aria2c fails — aria2 parses proxy env vars itself and aborts
on formats it doesn't understand, which is a confusing way to lose a download.

Reachable at `/dl` on the published port.

---

## 7. The gotchas that actually cost money

**Billing is per block, streaming.** A forgotten lease runs until your credit is
gone. Close the deployment manually — never rely on the 24 h trial cap as your
cleanup.

**Downloads bill at GPU rates.** Pulling Flux at $0.06/hr costs ~$0.01 for 10
min; on an A100 it's $0.40. Download into `/work` while the lease is already
open — you can't pre-warm it before you have a GPU.

**Persistent storage is not used at all.** Akash's docs are explicit that data
is lost when you close a deployment and on provider migration; `beta3`
persistent storage only survives *container restarts* and *deployment updates*
on the same provider. That partial guarantee costs ~2x per GB and narrows the
provider pool, so this kit skips it entirely and uses the root fs. Budget the
re-download.

**Storage is ephemeral — there is no persistent volume.** Everything (image,
Forge copy, models, logs) lives on the single 50Gi root fs. That is deliberate:
persistent storage costs roughly twice as much per GB and restricts bids to
providers advertising `feat-persistent-storage`. The cost is that models do not
survive a redeploy — re-download your checkpoint and LoRAs after each one.

**The panel quota is a guard, not a limit you should reach.** `PANEL_QUOTA_GB`
defaults to 20, against ~21GB of fixed cost (unpacked image, Forge copy,
runtime, logs) on a 50Gi disk. Raise it only if you also raise the root fs,
or the panel will fill the disk and Neo will die with an unrelated-looking
write error.

**Observability lives at `/dl/diag`.** Container stdout is unreachable from a
browser (it is only available through `provider-services lease-logs`), so the
entrypoint mirrors all of its output to `/work/logs/entrypoint.log`, and the
diag page shows that plus every service log, disk/memory/load, the process list
and the GPU that was actually allocated. The GPU section matters: `nvidia-smi`
is not in this image (the base is `nvidia/cuda:*-runtime`), so VRAM facts come
from torch. A provider handing over a 6GB card instead of the 12GB one you
bid on shows up there instead of as a mystery CUDA OOM.

**Storage class is irrelevant now.** With no persistent volume there is no
`class` to get wrong — the old `beta3`-vs-`beta1` (NVMe vs HDD) trap only
applied to named persistent volumes. Root-fs performance is the provider's
business.

**Root filesystem must be ≥ the image size.** Measured: the `v1` image is
**7.35 GB compressed / ~16 GB unpacked**, and the boot-time `cp -a
/opt/forge -> /work/forge-neo` duplicates Neo ($ work and $ opt are separate
mounts, so it is a genuine copy, not a hardlink) for roughly **18 GB of fixed
cost before any model**. `50Gi` in the SDLs therefore leaves about **32 GB for
models and logs**. Too small and the lease fails to start *after* you've already
paid for the bid.

**Models are on the root fs.** `/work/models` is the panel's destination, on
the same 50Gi filesystem as the image. The panel's `PANEL_QUOTA_GB=20` guard is
sized so that 20 GB of models plus the ~18 GB fixed cost stays inside 50Gi with
headroom to spare — your one checkpoint plus two LoRAs (~8 GB) is well clear of
it. See the quota note above.

**The provider pulls your image anonymously.** Make the registry repo public, or
the lease starts and immediately fails. `build.sh` checks `docker manifest
inspect` to confirm the manifest is publicly visible.

**`max_body_size` defaults to 1 MB.** Drag-and-drop LoRA/checkpoint uploads
fail without the `http_options` override that's already in the SDLs.

**Neo's credential parser crashes on `:` and `,`.** `api_auth` is split on
both. The entrypoint and `deploy-test.sh` both refuse to boot if `NEO_USER` or
`NEO_PASS` contains either — otherwise you get a silent restart loop that
bills GPU with no UI.

**`--gradio-auth` does not protect the API.** Neo registers `/sdapi/v1/*`
through `Api.add_api_route`, which only gets a dependency when `--api-auth` is
also set. Both are passed here, with the same credentials.

---

## 8. Card notes for the SDL you'll actually run

Machine A lists `rtx3060`, `t4`, `rtx5000`, `a10g` — **all entries must meet your
VRAM floor**, because the scheduler may pick any of them. The list filters *who
can bid*, not what you pay.

- `rtx3060` 12 GB, Ampere 8.6 — bf16, cu128 wheels all fine. SDXL comfortable;
  Flux Dev fp8 is *tight* at 12 GB.
- `t4` 16 GB, Turing 7.5 — works, but **no bf16**; fp16 + loss scaling only.
  No FlashAttention-2 (needs SM ≥ 8.0).
- `rtx5000` 16 GB, Turing 7.5 — same limits as T4, 448 GB/s instead of 320.
- `a10g` 24 GB, Ampere 8.6 — bigger and pricier fallback; most reliably in stock.

The image is CUDA 12.8 on purpose: 13.0 dropped Maxwell/Pascal/Volta
(sm_50–sm_72) and would kill any T4/P40 option, and its cu130 wheels are
built for Blackwell. 12.8 covers 7.5 through 9.0.

---

## 9. When you sit down to deploy

```sh
./build.sh                                  # once, before you hunt for a card
./watch-gpus.sh -m rtx3060                  # is it actually free? (PROV > 0)
./deploy-test.sh preflight                  # no spend
./deploy-test.sh create
./deploy-test.sh bids <dseq>
./deploy-test.sh accept <dseq> <provider>
```

Then, once it's live: open the URL, log in, queue your first run, and **watch
the escrow/usage in Console until the first images land** — that's the point
where a misconfigured ceiling or a runaway job would show up.

Container log (this is where the tunnel URL is printed):

```sh
provider-services lease-logs --dseq <dseq> --provider <prov> \
  --from trial --service ui --tail 100
```
