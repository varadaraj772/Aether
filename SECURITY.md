# Security Policy

Aether is designed to keep indexing and search on your Mac. Please help us keep it that way.

## Supported versions

Security fixes are accepted against the default branch.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Instead, email **varadaraj277@gmail.com** with:

- A description of the issue
- Steps to reproduce or a proof of concept if available
- Impact assessment (what an attacker could do)

You should receive an acknowledgement within a few days. We will coordinate a fix and disclosure timeline with you.

## Scope notes

Out of scope for “vulnerability” reports unless they create a real security issue:

- Model quality / ranking complaints
- First-launch download of the public embedding model from Hugging Face
- Unsigned local development builds

In scope examples:

- Path traversal or unintended file access beyond user-selected folders
- Unsafe handling of untrusted file content that leads to code execution
- Leakage of indexed content outside the local machine through the app itself
