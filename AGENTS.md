# AGENTS.md

## Project Overview

Kubernetes learning curriculum — chapters 01-10, each with 5 sub-sections containing `README.md` + `.yaml` examples. All content is Chinese. No code, no build, no CI — pure documentation + YAML manifests.

## Structure Convention

```
chapterXX-<topic>/
  0N-<subtopic>/
    README.md          # Deep tutorial: concepts → field tables → step-by-step kubectl → 思考题
    *.yaml             # Runnable examples with Chinese comments
```

- Chapters 01-10 = learning content, each chapter is independent
- Every README ends with thought questions (思考题) and nav link to next section

## Environment

- **Cluster**: kind (Kubernetes IN Docker), 3 nodes — 1 control-plane + 2 worker, K8s v1.31.0
- **Ingress**: NGINX Ingress Controller (kind-specific manifest)
- Environment setup is flexible — not tied to any specific cloud provider

## Writing Style

- Language: Chinese (中文)
- Depth: explain "why", not just "what"; step-by-step with expected `kubectl` output
- Images: only `nginx`, `busybox`, `alpine` (plus tool-specific images for Prometheus/Grafana/Jaeger)
- YAML files: must have Chinese comments on key fields
- Tables for field explanations, blockquotes (`>`) for tips/warnings
- Each README should be 200+ lines

## Key Files

- `PROGRESS.md` — learning progress tracker; update status (`⬜ → 🔧 → ✅`) with dates after each section is practiced

## Workflow

1. Write/edit content per section
2. Git commit after each completed section or meaningful change
3. Commit message format: `feat(chapterXX): <description>`
4. After practicing a section, update `PROGRESS.md` and commit

## Git Conventions

- Branch prefix format: `<prefix>/linuxea_<suffix>` (e.g. `feat/linuxea_new_chapter`)
- No CI, lint, or test pipeline
