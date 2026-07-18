# Contributing to Aether

Thanks for helping improve Aether. This project is local-first semantic file search for macOS.

## Development setup

1. Fork and clone the repository.
2. Install dependencies:

```bash
./Scripts/setup-backend.sh
```

3. Open `Aether.xcodeproj` in Xcode and run the **Aether** scheme.
4. Optional: open `landing/index.html` in a browser while iterating on the marketing page.

### Backend tests

```bash
cd Backend
./venv/bin/python -m unittest discover -s tests -v
```

### Manual smoke checks

See [`Scripts/QA_SMOKE_CHECKLIST.txt`](Scripts/QA_SMOKE_CHECKLIST.txt).

## Pull requests

- Keep changes focused. Prefer small PRs over large mixed ones.
- Match existing Swift and Python style in the files you touch.
- Add or update backend tests when you change search, indexing, or the RPC bridge.
- Do not commit `Backend/venv/`, Xcode `DerivedData/`, or local secrets.
- Update `README.md` or `AETHER_SPEC.txt` when behavior or setup steps change.

## Suggested focus areas

- Search ranking and recall quality
- Indexing performance and reliability
- Accessibility and keyboard UX
- Packaging / distribution (bundled Python remains a hard problem)
- Docs and onboarding clarity

## Reporting bugs

Use GitHub Issues. Include:

- macOS and Xcode versions
- Steps to reproduce
- Expected vs actual behavior
- Relevant Console lines prefixed with `[Aether backend]`

## Security

Do not file public issues for sensitive security reports. See [`SECURITY.md`](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the MIT License.
