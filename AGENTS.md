# AGENTS.md

## Project Overview

Kubernetes learning curriculum — 11 chapters (00-10), each with 5 sub-sections containing `README.md` + `.yaml` examples. All content is Chinese. Total: ~232 files, ~14K lines.

## Structure Convention

```
chapterXX-<topic>/
  0N-<subtopic>/
    README.md          # Deep tutorial: concepts → field tables → step-by-step kubectl → 思考题
    *.yaml             # Runnable examples with Chinese comments
```

- Chapter 00 = environment setup (AWS Lightsail + kind 3-node cluster)
- Chapters 01-10 = learning content, each chapter is independent
- Every README ends with thought questions (思考题) and nav link to next section

## Writing Style

- Language: Chinese (中文)
- Depth: explain "why", not just "what"; step-by-step with expected `kubectl` output
- Images: only `nginx`, `busybox`, `alpine` (plus tool-specific images for Prometheus/Grafana/Jaeger)
- YAML files: must have Chinese comments on key fields
- Tables for field explanations, blockquotes (`>`) for tips/warnings
- Each README should be 200+ lines

## Key Files

- `PROGRESS.md` — learning progress tracker; update status (`⬜ → 🔧 → ✅`) with dates after each section is practiced
- `chapter00-env-setup/kind-cluster.yaml` — 3-node kind config (1 control-plane + 2 worker, port-mapped 80/443)

## Workflow

1. Write/edit content per section
2. Git commit after each completed section or meaningful change
3. Commit message format: `feat(chapterXX): <description>`
4. After practicing a section, update `PROGRESS.md` and commit

## Git Conventions

- Branch prefix format: `<prefix>/linuxea_<suffix>` (e.g. `feat/linuxea_new_chapter`)
- No existing CI, lint, or test pipeline — content is documentation + YAML manifests
- No code generation or build steps
