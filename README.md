# v2x-downloader

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Shell](https://img.shields.io/badge/shell-bash-89e051.svg)
![rclone](https://img.shields.io/badge/requires-rclone%20%E2%89%A5%201.63-blue.svg)

**English** | [简体中文](README.zh-CN.md)

A resumable, rate-limit-aware downloader for the public V2X autonomous-driving datasets (DAIR-V2X and V2X-Seq) hosted on Google Drive.

Pulling 141 GiB off Google Drive is mostly a fight against two things: interrupted transfers and rate limits. This script wraps `rclone` with settings tuned for exactly that — it resumes where it left off, throttles API calls before Google throttles you, and verifies every file by MD5 when it's done.

## Why not gdown

`gdown` is the usual answer for Google Drive downloads, but it does not hold up at this scale. Large transfers get interrupted, and the retries needed to recover from that are what trip Google's rate limiter. `rclone` resumes natively and lets you cap the request rate up front, which avoids the failure mode instead of reacting to it.

## Features

- **Resumable** — interrupt anytime; re-run the same command and completed files are skipped
- **Rate-limit aware** — caps QPS proactively rather than backing off after a 403
- **Verified** — MD5 comparison against the remote, with a distinct repair path for silently corrupted files
- **Selective** — fetch a single sub-dataset instead of all 141 GiB
- **Headless** — service account auth, no browser required on the server
- **Non-invasive** — configures rclone via environment variables; never writes to your `rclone.conf`

## The dataset

44 files, **141.3 GiB** total, in two top-level directories:

| Directory | Contents |
|---|---|
| `DAIR-V2X (CVPR2022)` | DAIR-V2X-C / DAIR-V2X-I / DAIR-V2X-V, each with an Example and a Full Dataset |
| `V2X-Seq (CVPR2023)` | Sequential-Perception-Dataset (incl. test split), Trajectory-Forecasting-Dataset |

Largest single file is 8.59 GiB. **Most of the data ships as split archives** — `.z01`–`.z04` plus a same-named `.zip` form one archive, and you need every part to extract it. See [Extracting split archives](#extracting-split-archives).

One file, `ReadMe.docx`, is a native Google Docs document. It shows a size of `-1` in `list` — that's expected, and it is exported to a standard `.docx` on download.

## Requirements

- Ubuntu 22.04 (or any Linux with bash); tested on Ubuntu 22 server and macOS
- `rclone` **≥ 1.63** — earlier versions lack multi-threaded downloads
- A Google account (any account; see [Credentials](#credentials))

## Install rclone

```bash
sudo -v ; curl https://rclone.org/install.sh | sudo bash
rclone version
```

The version in Ubuntu's apt repository is usually too old — prefer the official installer.

## Credentials

The target folder is shared as "anyone with the link can view", so **any** authenticated Google identity can read it. You do not need the folder owner to grant you anything. Since servers have no browser, a service account is the path of least resistance.

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
RCLONE_REMOTE=gdrive ./download_v2x.sh download
```

Note that rclone's built-in OAuth client ID is shared by all rclone users worldwide and is more prone to global rate limiting. A service account gets its own quota.

## Usage

```bash
chmod +x download_v2x.sh

./download_v2x.sh check      # verify credentials, count files and total size
./download_v2x.sh list       # list every remote file
./download_v2x.sh download   # download (default command)
./download_v2x.sh verify     # MD5-verify local against remote
```

For a full run, put it in the background:

```bash
DEST_DIR=/data/v2x SA_FILE=/etc/v2x/sa.json \
  nohup ./download_v2x.sh download > /dev/null 2>&1 &

tail -f logs/download_*.log
```

**Interrupted? Just re-run the same command.** The script uses `rclone copy`, so finished files are skipped and nothing local is ever deleted.

## Verification

```bash
./download_v2x.sh verify
```

Compares MD5 hashes against the remote and writes differences to `logs/missing.txt` and `logs/differ.txt`, then prints the matching repair command:

| Problem | Fix |
|---|---|
| File missing | `./download_v2x.sh download` |
| File present but content differs | `CHECKSUM=1 ./download_v2x.sh download` |

The second case is worth understanding. `rclone copy` decides whether to re-transfer based on size + modification time. If a file's contents are corrupted but its size and mtime still match the remote — silent disk corruption, for instance — a plain `download` considers it up to date and skips it, while `verify` keeps reporting a mismatch. `CHECKSUM=1` switches the comparison to MD5 so those files are actually re-fetched. It is not the default because rehashing local files is slow on a dataset this size.

`ReadMe.docx` has no MD5 (Google Docs exports aren't byte-stable), so it is skipped rather than verified. The script says so explicitly when this happens.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `DEST_DIR` | `./v2x-data` | Local destination directory |
| `SA_FILE` | `./service-account.json` | Path to the service account key |
| `RCLONE_REMOTE` | *empty* | Use an existing rclone remote instead; overrides `SA_FILE` |
| `TRANSFERS` | `4` | Concurrent file transfers |
| `TPSLIMIT` | `8` | API request rate cap (QPS) |
| `BWLIMIT` | `off` | Bandwidth limit, e.g. `20M` |
| `INCLUDE` | *empty* | Download only matching paths, e.g. `'DAIR-V2X (CVPR2022)/**'` |
| `CHECKSUM` | `0` | Set to `1` to compare by MD5 instead of size+mtime |
| `LOG_DIR` | `./logs` | Log directory |
| `FOLDER_ID` | dataset folder ID | Point the script at a different Drive folder |

### Downloading a subset

```bash
./download_v2x.sh list                                      # see what's there
INCLUDE='DAIR-V2X (CVPR2022)/**' ./download_v2x.sh download
```

⚠️ **When filtering by filename, include the split parts.** `INCLUDE='**/single-vehicle-side-velodyne.zip'` matches only the last part and leaves out `.z01`–`.z04`, producing a `.zip` that cannot be extracted. Match the whole group instead:

```bash
INCLUDE='**/single-vehicle-side-velodyne.*' ./download_v2x.sh download
```

## Extracting split archives

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

If you still hit `rateLimitExceeded`, lower the concurrency: `TRANSFERS=2 TPSLIMIT=4 ./download_v2x.sh download`.

A **per-file** download quota also exists and is independent of your account — popular public files get temporarily locked when many people download them. Switching service accounts does not help; wait 24 hours. Since downloads resume, nothing already fetched is re-transferred.

## Security

The service account key is a long-lived credential. Anyone holding it can call the Google Cloud APIs enabled on your project.

- `.gitignore` excludes `*.json` wholesale so a key can't be committed by accident
- Keep it at `chmod 600`
- Revoke it from the Cloud Console when you're done

## Disclaimer

This repository contains **only a download tool**. It does not host, mirror, or redistribute any data.

The datasets are the work of their original authors — DAIR-V2X (CVPR 2022) and V2X-Seq (CVPR 2023). Their licensing terms, permitted uses, and citation requirements are set by those authors, not by this project. Consult the `ReadMe.docx` included in the Drive folder and the corresponding papers before using the data, and cite them in any resulting work.

## License

[MIT](LICENSE)
