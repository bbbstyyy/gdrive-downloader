# gdrive-downloader

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Shell](https://img.shields.io/badge/shell-bash-89e051.svg)
![rclone](https://img.shields.io/badge/requires-rclone%20%E2%89%A5%201.63-blue.svg)

**English** | [简体中文](README.zh-CN.md)

A resumable, rate-limit-aware downloader for **any Google Drive link** — a whole folder, a single file, or a Google Doc — including optional routing through a network proxy.

> **Renamed from `v2x-downloader`.** GitHub redirects the old repository URL automatically, but an existing local clone needs its remote updated: `git remote set-url origin <new-url>`. The V2X preset wrapper moved from `./download_v2x.sh` to [`./examples/download_v2x.sh`](examples/download_v2x.sh).

The project started as a way to pull the 141 GiB public V2X autonomous-driving datasets (DAIR-V2X and V2X-Seq) off Google Drive, where the fight is against interrupted transfers and rate limits. That capability is still here and still the default path for folder links; it has just been generalized, so the same script now also handles a bare file link or a Docs/Sheets/Slides URL.

## Features

- **Any Drive link** — folder, `/file/d/<ID>`, legacy `open?id=`, Docs/Sheets/Slides/Drawings, or a bare ID
- **Resumable** — interrupt anytime; re-run the same command and completed files are skipped
- **Rate-limit aware** — caps QPS proactively rather than backing off after a 403
- **Verified** — MD5 comparison against the remote, with a distinct repair path for silently corrupted files
- **Proxy-aware** — `--proxy` (or the `PROXY` env var) routes both the rclone and curl paths
- **No credentials needed for single files** — a public file link is fetched over a direct URL; rclone is only required for folder links
- **Selective** — fetch a single sub-dataset instead of all 141 GiB
- **Headless** — service account auth, no browser required on the server
- **Non-invasive** — configures rclone via environment variables; never writes to your `rclone.conf`

### Why not gdown

`gdown` is the usual answer for Google Drive downloads, but it does not hold up at scale. Large transfers get interrupted, and the retries needed to recover from that are what trip Google's rate limiter. `rclone` resumes natively and lets you cap the request rate up front, which avoids the failure mode instead of reacting to it. For a single small file, though, the script does use a plain direct URL — there is nothing to resume and no rate limit worth managing.

## What each link type does

| Link | Path used | Behaviour |
|---|---|---|
| `drive.google.com/drive/folders/<ID>` | rclone | Full tree, resumable, MD5-verified, multi-threaded |
| `drive.google.com/file/d/<ID>/view` | `rclone backend copyid`, falling back to the direct URL with curl | Resumable; falls back automatically when there is no credential, or with `--strategy curl` |
| `drive.google.com/open?id=<ID>`, bare ID | probed once | Tries folder listing first, otherwise treats it as a single file (`--type` overrides) |
| `docs.google.com/{document,spreadsheets,presentation,drawings}/d/<ID>` | curl | Exported to `.docx` / `.xlsx` / `.pptx` / `.png` (`--format` overrides; a `#gid=…` sheet defaults to `.csv`) |
| any of the above with `?resourcekey=…` | both | The resource key is forwarded to rclone and to the direct URL |

## Repository layout

| Path | What it is |
|---|---|
| `gdrive-download.sh` | The downloader. This is the only file you actually need. |
| `examples/download_v2x.sh` | Preset wrapper for the V2X dataset folder — copy it as a template for a folder of your own |
| `README.md` · `README.zh-CN.md` | Docs, English and 简体中文 |

## Requirements

- Ubuntu 22.04 (or any Linux/macOS with bash 3.2+)
- `rclone` **≥ 1.63** — needed for folder links, and for the resumable single-file path (`backend copyid`); earlier versions lack multi-threaded downloads
- `curl` — needed for the single-file fallback and Google Docs export
- A Google account (any account; see [Credentials](#credentials)) — only for folder links and the rclone single-file path

## Install rclone

```bash
sudo -v ; curl https://rclone.org/install.sh | sudo bash
rclone version
```

The version in Ubuntu's apt repository is usually too old — prefer the official installer.

## Credentials

Folder links (and the credentialed single-file path) are read using *any* authenticated Google identity — you do not need the folder owner to grant you anything beyond the link being shared as "anyone with the link can view". Since servers have no browser, a service account is the path of least resistance.

### Option A — service account (recommended)

One-time setup in any Google Cloud project of your own:

1. Go to https://console.cloud.google.com/ and create or select a project
2. Enable the **Google Drive API**: https://console.cloud.google.com/apis/library/drive.googleapis.com
3. **IAM & Admin → Service Accounts → Create service account**. Give it a name and click through — **leave the roles section empty**
4. Open the service account → **Keys → Add key → Create new key → JSON** → download
5. Copy it to the server:

```bash
scp service-account.json user@server:/etc/v2x/sa.json
ssh user@server 'chmod 600 /etc/v2x/sa.json'
```

Leaving the roles empty is correct. IAM roles govern access to Google Cloud resources; here the account is only used to authenticate as *some* Google identity so it can read a publicly shared folder. It consumes none of your Drive quota.

> If your organization blocks service account key creation (`iam.disableServiceAccountKeyCreation`), use a personal Google account instead — the project exists purely for authentication and has no bearing on data ownership.

### Option B — reuse an existing rclone remote

If you already have a Drive remote configured (say, `gdrive`):

```bash
./gdrive-download.sh download '<link>' --remote gdrive
```

Note that rclone's built-in OAuth client ID is shared by all rclone users worldwide and is more prone to global rate limiting. A service account gets its own quota.

## Usage

```bash
chmod +x gdrive-download.sh

./gdrive-download.sh download '<link>'          # download (the default command)
./gdrive-download.sh check    '<link>'          # verify credentials, report the remote
./gdrive-download.sh list     '<link>'          # list what is there
./gdrive-download.sh verify   '<link>'          # check local against remote
./gdrive-download.sh info     '<link>'          # just parse the link, no download, no credentials
```

Everything is also settable as an option or an environment variable; `./gdrive-download.sh -h` prints the full list.

```bash
# folder link, into /data/v2x, with a service account
DEST_DIR=/data/v2x SA_FILE=/etc/v2x/sa.json \
  nohup ./gdrive-download.sh download 'https://drive.google.com/drive/folders/1gnrw5llXAIxuB9sEKKCm6xTaJ5HQAw2e' \
  > /dev/null 2>&1 &
tail -f logs/download_*.log

# a single public file — no credentials involved
./gdrive-download.sh download 'https://drive.google.com/file/d/<FILE_ID>/view' -d ./data

# a Google Doc, exported explicitly
./gdrive-download.sh download 'https://docs.google.com/document/d/<DOC_ID>/edit' -n readme.docx
```

**Interrupted? Just re-run the same command.** Folder downloads use `rclone copy` and single files resume over HTTP range requests, so finished data is skipped and nothing local is ever deleted (no `sync`, no `--delete`).

### Proxy

```bash
./gdrive-download.sh download '<link>' --proxy http://127.0.0.1:7890
./gdrive-download.sh download '<link>' --proxy socks5h://127.0.0.1:1080   # single files / Docs
PROXY=http://user:pass@10.0.0.1:3128 ./gdrive-download.sh download '<link>'
./gdrive-download.sh download '<link>' --no-proxy    # ignore ambient HTTP(S)_PROXY
```

The proxy is applied to both engines: `--http-proxy` for rclone, `--proxy` for curl. Requests less than `http://` are assumed to be plain host:port and get an `http://` prefix.

Two notes:

- **Folder links need an HTTP(S) proxy.** rclone's global `--http-proxy` is an HTTP proxy setting; use an HTTP/HTTPS proxy for folder downloads.
- **SOCKS5 is available on the curl path** — single files and Google Docs exports (`socks5://` resolves names locally, `socks5h://` resolves them at the proxy, which is usually what you want).

Both tools also honour the standard `HTTP_PROXY` / `HTTPS_PROXY` environment variables on their own, so a machine-wide proxy setting works with no flags at all.

## Verification

```bash
./gdrive-download.sh verify '<link>'
```

For a **folder**, MD5 hashes are compared against the remote and differences are written to `logs/missing.txt` and `logs/differ.txt`, along with the matching repair command:

| Problem | Fix |
|---|---|
| File missing | `./gdrive-download.sh download '<link>'` |
| File present but content differs | `CHECKSUM=1 ./gdrive-download.sh download '<link>'` |

The second case is worth understanding. `rclone copy` decides whether to re-transfer based on size + modification time. If a file's contents are corrupted but its size and mtime still match the remote — silent disk corruption, for instance — a plain `download` considers it up to date and skips it, while `verify` keeps reporting a mismatch. `CHECKSUM=1` switches the comparison to MD5 so those files are actually re-fetched. It is not the default because rehashing local files is slow on a dataset this size.

For a **single file** or a **Doc export**, `verify` compares the local size against the remote `Content-Length` and prints the local MD5 — there is no cheap way to obtain a remote MD5 for one file without a Drive API call, so byte-exact verification of a single file rests on rclone's own post-transfer hash check on the `copyid` path. Re-running `download --overwrite` is the way to repair a suspect single file.

## Options and environment variables

| Option | Variable | Default | Description |
|---|---|---|---|
| `<link>` | `LINK` / `URL` / `GDRIVE_URL` | — | The Drive link or bare ID to work on |
| `-d, --dest` | `DEST_DIR` | `./downloads` | Local destination directory |
| `-p, --proxy` | `PROXY` | *empty* | Proxy URL, e.g. `http://127.0.0.1:7890`, `socks5h://127.0.0.1:1080` |
| `--no-proxy` | — | off | Ignore `HTTP_PROXY` / `HTTPS_PROXY` from the environment |
| `-n, --name` | `NAME` | *derived* | Output filename (single file / Doc export) |
| `-f, --format` | `FORMAT` | by doc type | Export format for Google Docs: `docx`, `xlsx`, `pptx`, `pdf`, `csv`, `png` |
| `--sa` | `SA_FILE` | `./service-account.json` | Path to the service account key |
| `--remote` | `RCLONE_REMOTE` | *empty* | Use an existing rclone remote instead; overrides `SA_FILE` |
| `--type` | `KIND_OVERRIDE` | *auto* | Force `folder` or `file` when the link is ambiguous |
| `--strategy` | `STRATEGY` | `auto` | Single-file path: `auto`, `rclone`, or `curl` |
| `--include` | `INCLUDE` | *empty* | Download only matching paths, folder links only |
| `--threads` | `TRANSFERS` | `4` | Concurrent file transfers |
| `--tpslimit` | `TPSLIMIT` | `8` | API request rate cap (QPS) |
| `--bwlimit` | `BWLIMIT` | `off` | Bandwidth limit, e.g. `20M` |
| `--checksum` | `CHECKSUM` | `0` | Compare by MD5 instead of size+mtime (folder links) |
| `--overwrite` | `OVERWRITE` | `0` | Re-download even if a same-sized file already exists |
| `--log-dir` | `LOG_DIR` | `./logs` | Log and cookie/probe scratch directory |

## Downloading a subset (folder links)

```bash
./gdrive-download.sh list '<folder link>'                   # see what's there
./gdrive-download.sh download '<folder link>' --include 'DAIR-V2X (CVPR2022)/**'
```

⚠️ **When filtering by filename, include the split parts.** `--include '**/single-vehicle-side-velodyne.zip'` matches only the last part and leaves out `.z01`–`.z04`, producing a `.zip` that cannot be extracted. Match the whole group instead:

```bash
./gdrive-download.sh download '<folder link>' --include '**/single-vehicle-side-velodyne.*'
```

## The V2X datasets (why this exists)

The repository originally existed for this one folder, so it ships as a worked example: [`examples/download_v2x.sh`](examples/download_v2x.sh) is a 27-line wrapper that pins the link and the default destination to the dataset, and forwards everything else to `gdrive-download.sh`.

```bash
./examples/download_v2x.sh check      # verify credentials, count files and total size
./examples/download_v2x.sh list       # list every remote file
./examples/download_v2x.sh download    # download (default command)
./examples/download_v2x.sh verify      # MD5-verify local against remote
```

Because it is just a preset, and not a second implementation, everything the main script learns (proxy support, new commands, better defaults) applies here too. To do the same for a folder of your own, copy the wrapper and change two variables.

Everything below applies to that folder.

### Contents

44 files, **141.3 GiB** total, in two top-level directories:

| Directory | Contents |
|---|---|
| `DAIR-V2X (CVPR2022)` | DAIR-V2X-C / DAIR-V2X-I / DAIR-V2X-V, each with an Example and a Full Dataset |
| `V2X-Seq (CVPR2023)` | Sequential-Perception-Dataset (incl. test split), Trajectory-Forecasting-Dataset |

Largest single file is 8.59 GiB. **Most of the data ships as split archives** — `.z01`–`.z04` plus a same-named `.zip` form one archive, and you need every part to extract it. See [Extracting split archives](#extracting-split-archives).

One file, `ReadMe.docx`, is a native Google Docs document. It shows a size of `-1` in `list` — that's expected, and rclone exports it to a standard `.docx` on download.

### Extracting split archives

`.z01`–`.z04` plus the same-named `.zip` (which is the *last* part) form one WinZip split archive. Install the tools first:

```bash
sudo apt update && sudo apt install -y zip p7zip-full
```

**Option 1 — 7z, handles the parts directly (preferred):**

```bash
7z x single-vehicle-side-velodyne.zip
```

**Option 2 — merge, then extract** (all parts must be in the same directory):

```bash
cd "DAIR-V2X (CVPR2022)/DAIR-V2X-V/Full Dataset (train&val)"
zip -s 0 single-vehicle-side-velodyne.zip --out combined.zip
unzip combined.zip
rm combined.zip
```

Option 2's `zip -s 0` writes a merged copy as large as the original data, so it needs roughly double the disk space. Option 1 avoids that.

## Rate limits

Google Drive enforces per-identity QPS and daily transfer caps. The script mitigates this by default:

- `--tpslimit 8` caps the request rate up front, which is cheaper than recovering from a 403
- `--fast-list` lists the whole tree in one pass, minimizing listing API calls
- `--retries 10 --low-level-retries 20` on top of rclone's built-in exponential backoff

If you still hit `rateLimitExceeded`, lower the concurrency: `--threads 2 --tpslimit 4`.

A **per-file** download quota also exists and is independent of your account — popular public files get temporarily locked when many people download them. Switching service accounts does not help; wait 24 hours. Since downloads resume, nothing already fetched is re-transferred. The single-file curl path detects this case and says so rather than writing an HTML error page to disk.

## Security

The service account key is a long-lived credential. Anyone holding it can call the Google Cloud APIs enabled on your project.

- `.gitignore` excludes `*.json` wholesale so a key can't be committed by accident
- Keep it at `chmod 600`
- Revoke it from the Cloud Console when you're done

Proxy URLs may contain credentials; pass them via `--proxy` or `PROXY` and avoid committing them into shell scripts.

## Disclaimer

This repository contains **only a download tool**. It does not host, mirror, or redistribute any data.

The datasets are the work of their original authors — DAIR-V2X (CVPR 2022) and V2X-Seq (CVPR 2023). Their licensing terms, permitted uses, and citation requirements are set by those authors, not by this project. Consult the `ReadMe.docx` included in the Drive folder and the corresponding papers before using the data, and cite them in any resulting work. The same applies to any other link you point this script at.

## License

[MIT](LICENSE)
