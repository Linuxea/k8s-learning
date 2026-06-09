# AGENTS.md

## Project

Kubernetes 互动式教学课程 — 纯文档 + YAML manifests，无代码/构建/CI。内容全中文，镜像仅用 `nginx:1.27`、`busybox:1.36`、`alpine`。

```
chapterXX-<topic>/0N-<subtopic>/README.md + *.yaml
```

每个 README 末尾有思考题和下一节导航链接。`PROGRESS.md` 追踪进度和远程环境信息。

## Environment

| 项 | 值 |
|----|----|
| 集群 | kind 3 节点 (k8s-learn)，腾讯云上海 `124.221.119.24` |
| SSH | `ssh tencent-light-shanghai`（密钥 `~/.ssh/tencent_light_shanghai`） |
| kubectl | **必须 SSH 进远程执行**，本地无法直连 |
| 项目路径 | 远程 `/home/ubuntu/k8s-learning`，本地 `/home/linuxea/code/k8s-learning` |

> 远程实例在国内，`raw.githubusercontent.com` 和 `registry.k8s.io` 无法直接访问。下载 YAML 在本地上传（`scp`），镜像替换阿里云源：`s|registry.k8s.io/|registry.aliyuncs.com/google_containers/|g`。

## Teaching Session Rules

这些规则在**学生互动式教学**时生效：

- **学生自己敲命令**，AI 只给命令，不代执行
- **每次只给一条命令**，等学生执行完、反馈结果后再继续
- **先讲解 YAML 再 apply** — AI 负责读文件并向学生讲清楚配置内容，学生理解了再给 apply 命令。不要让学生自己去 `cat`，也不要直接丢 `kubectl apply`
- 学生提出"为什么"时，先让他猜，再给答案
- 不要一次输出 3 条以上命令或大段解读
- 学生喊停就停，不赶进度
- README 是课后参考手册，不是讲课稿

## Post-Session Workflow

一节学完后必须执行四步：

1. **更新 README** — 把学生的困惑、踩坑、误解加进「常见困惑」节
2. **更新 YAML 注释** — 标注实际操作中发现的坑（如镜像拉取/端口冲突等）
3. **更新 PROGRESS.md** — 标记 `✅ 已完成` + 日期
4. **Git commit** — 格式 `feat(chapterXX): <description>`

## Git

- 只在 main 分支操作，无 PR/CI
- Commit 格式: `feat|refactor|docs(chapterXX): description`
