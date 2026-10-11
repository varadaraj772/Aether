# Aether

**Local semantic file search for macOS.**

Index folders on your Mac and search by name, content, or meaning - nothing leaves your machine.

![Platform](https://img.shields.io/badge/platform-macOS-black)
![License](https://img.shields.io/badge/license-MIT-blue)
![Python](https://img.shields.io/badge/python-3.10%2B-yellow)
![Swift](https://img.shields.io/badge/SwiftUI-native-orange)

## Why Aether?

Spotlight is great when you know the filename. Cloud AI search often wants your files. Aether sits in between:

- Search by **meaning**, keywords, or name
- Index **locally** with LanceDB + a local embedding model
- Keep a Spotlight-style **launcher** and a full **workspace** with preview & Quick Look

Product overview: [`AETHER_SPEC.txt`](AETHER_SPEC.txt) · Site: [aether.varada.me](https://aether.varada.me) · Source: [`landing/`](landing/)

## Features

- Semantic + keyword hybrid search across text, code, documents, images, audio, and video (local `EmbeddingGemma 2`)
- Launcher (`⌘⇧Space`) and three-pane workspace
- Folder browse, smart collections, folder-scoped search
- Indexing with progress, cancel, background jobs, and index health in Settings
- OCR for images; scanned PDF OCR fallback
- Related files, duplicate detection, live sync
- User-configurable exclude paths
- Menu bar access
- 100% local - no account, no telemetry

## Requirements

- macOS (developed against recent macOS / Xcode toolchains)
- Xcode
- Python **3.10+**

## Quick start

```bash
git clone https://github.com/varadaraj772/Aether.git
cd Aether
./Scripts/setup-backend.sh
open Aether.xcodeproj
```

Then run the **Aether** scheme in Xcode.

The setup script:

- Creates or repairs `Backend/venv`
- Installs Python dependencies (including OCR / PDF helpers)
- Preloads the embedding model into your Hugging Face cache (first time can take a few minutes and needs network)

Override the interpreter if needed:

```bash
export AETHER_PYTHON=/path/to/python3
```

## Usage

| Shortcut | Action |
|----------|--------|
| ⌘⇧Space | Toggle launcher / hide window |
| Esc | Back to launcher (or close Quick Look first) |
| ↑↓ | Navigate results |
| Return | Open selected file |
| ⌘Return | Open in workspace with preview |
| Space | Quick Look selected result (workspace) |
| ⌥⌘F | Toggle This Folder / All Folders scope |

### First run

1. Add folders (sidebar or drag & drop).
2. Index selected or all folders.
3. Press ⌘⇧Space and search.

## Data locations

| Path | Purpose |
|------|---------|
| `~/.aether/folders.json` | Folders, recent/saved searches, excludes, meta |
| `~/.aether/db/` | LanceDB vector index |
| `~/.cache/huggingface/` | Embedding model cache (via Hugging Face Hub) |

## Project layout

```
Aether/                 SwiftUI app
Backend/                Python JSON-RPC bridge + search/index
Scripts/                setup, package, QA checklist, icons
landing/                Marketing site (hosted at https://aether.varada.me)
AETHER_SPEC.txt         Product / architecture overview
```

## Development

```bash
# Backend tests
cd Backend
./venv/bin/python -m unittest discover -s tests -v

# Package unsigned Release .app (Python venv still external)
./Scripts/package-app.sh
```

Manual QA: [`Scripts/QA_SMOKE_CHECKLIST.txt`](Scripts/QA_SMOKE_CHECKLIST.txt)

Contributing guide: [`CONTRIBUTING.md`](CONTRIBUTING.md)

## Troubleshooting

**Python backend is not available**

Run `./Scripts/setup-backend.sh` and rebuild. Use **Retry** in the app after fixing setup.

**Slow first launch**

The embedding model downloads once (needs network), then loads from cache. Later launches still spend time loading Torch/the model into memory; the UI should become usable after the backend process responds.

**Scanned PDFs have no searchable text**

Ensure OCR dependencies are installed via setup, then re-index the folder.

**Backend exited unexpectedly**

Check Console for `[Aether backend]` logs. The app attempts auto-recovery; re-index if indexing was interrupted.

## Privacy

Aether indexes and searches on your Mac. There is no cloud sync of your corpus and no analytics SDK. The first model download uses Hugging Face Hub (public model weights only).

### Search model migration

New installs use `google/embeddinggemma-2` with retrieval-specific query/document prompts. Existing indexes made with the older MiniLM model are detected automatically; the next index operation rebuilds the incompatible vector table. Until then, filename/content matching remains available. Images, audio, and video are embedded natively into the same 768-dimensional space, enabling text-to-media, media-to-media, and cross-modal related-file search.

## License

[MIT](LICENSE)

## Acknowledgments

- [sentence-transformers](https://www.sbert.net/) / `all-MiniLM-L6-v2`
- [LanceDB](https://lancedb.github.io/lancedb/)
- RapidOCR / pypdf / pypdfium2 for extraction and OCR
