FROM python:3.12-alpine

# ffmpeg / ffprobe：转码与探测的全部依赖，Alpine 包已带 libx264 / libx265
RUN apk add --no-cache ffmpeg tzdata

WORKDIR /app
COPY app.py /app/app.py
# 语法错误在构建期就暴露出来，而不是变成容器反复重启
RUN python3 -m py_compile /app/app.py

# 顺手把 hls.js 打进镜像，让 VPS 在运行期完全不依赖公网 CDN；
# 构建时拉不到也不影响镜像可用（前端会自动回退到 CDN）
RUN mkdir -p /app/vendor && \
    (wget -qO /app/vendor/hls.js https://cdn.jsdelivr.net/npm/hls.js@1/dist/hls.min.js || \
     wget -qO /app/vendor/hls.js https://unpkg.com/hls.js@1/dist/hls.min.js || \
     rm -f /app/vendor/hls.js) ; true

ENV PYTHONUNBUFFERED=1 \
    TZ=Asia/Shanghai

EXPOSE 8000
CMD ["python3", "/app/app.py"]
