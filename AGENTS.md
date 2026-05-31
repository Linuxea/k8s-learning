# AGENTS.md

## Project Overview

Kubernetes learning curriculum — 11 chapters (00-10), each with 5 sub-sections containing `README.md` + `.yaml` examples. All content is Chinese. No code, no build, no CI — pure documentation + YAML manifests.

## Structure Convention

```
chapterXX-<topic>/
  0N-<subtopic>/
    README.md          # Deep tutorial: concepts → field tables → step-by-step kubectl → 思考题
    *.yaml             # Runnable examples with Chinese comments
scripts/
  provision.sh        # tccli 创建 CVM 竞价实例
  setup-server.sh      # First-time: install Docker/kind/kubectl + create cluster + Ingress
  setup-local.sh       # Local kubectl remote access to CVM cluster
```

- Chapter 00 = environment setup (腾讯云 CVM 竞价实例 + kind 3-node cluster)
- Chapters 01-10 = learning content, each chapter is independent
- Every README ends with thought questions (思考题) and nav link to next section

## Infrastructure

- **VPS**: 腾讯云 CVM 竞价实例, 2 vCPU / 4GB RAM (ap-guangzhou), Ubuntu 24.04, 按秒计费
- **CLI**: tccli (`tccli cvm RunInstances` / `TerminateInstances` 管理实例生命周期)
- **Cluster**: kind (Kubernetes IN Docker), 3 nodes — 1 control-plane + 2 worker, K8s v1.31.0
- **Ingress**: NGINX Ingress Controller (kind-specific manifest)
- Kind cluster config: `chapter00-env-setup/kind-cluster.yaml` (port-mapped 80/443)
- Scripts run on server via SSH pipe: `ssh ubuntu@IP 'bash -s' < scripts/setup-server.sh`

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
- No CI, lint, or test pipeline
