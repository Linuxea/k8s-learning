# 多阶段构建 Dockerfile：基于 nginx 的 Web 应用
# 为什么用多阶段构建？将构建环境和运行环境分离，最终镜像更小、更安全

# ---- 构建阶段 ----
FROM busybox:1.36 AS builder

# 在构建阶段生成静态文件，模拟真实的构建过程
# 实际项目中这里可能是 npm run build、go build 等
RUN mkdir -p /build && \
    echo '<!DOCTYPE html>' > /build/index.html && \
    echo '<html><head><title>K8s CI/CD Demo</title></head>' >> /build/index.html && \
    echo '<body>' >> /build/index.html && \
    echo '<h1>Hello from Kubernetes CI/CD demo!</h1>' >> /build/index.html && \
    echo '<p>Version: v1.0.0</p>' >> /build/index.html && \
    echo '<p>Built with multi-stage Dockerfile</p>' >> /build/index.html && \
    echo '</body></html>' >> /build/index.html

# ---- 运行阶段 ----
FROM nginx:1.25-alpine

# 只从 builder 阶段复制构建产物，不包含构建工具链
COPY --from=builder /build/index.html /usr/share/nginx/html/index.html

# nginx 默认监听 80 端口，EXPOSE 声明端口是文档性质的，不实际发布
EXPOSE 80

# 使用 nginx 默认的 CMD，不需要覆盖
# CMD ["nginx", "-g", "daemon off;"]
