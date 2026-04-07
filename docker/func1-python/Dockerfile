FROM python:3.12-slim

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG ALL_PROXY
ARG NO_PROXY

ENV HTTP_PROXY=${HTTP_PROXY}
ENV HTTPS_PROXY=${HTTPS_PROXY}
ENV ALL_PROXY=${ALL_PROXY}
ENV NO_PROXY=${NO_PROXY}
ENV http_proxy=${HTTP_PROXY}
ENV https_proxy=${HTTPS_PROXY}
ENV all_proxy=${ALL_PROXY}
ENV no_proxy=${NO_PROXY}
ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY workers/func1-python/requirements.txt /app/requirements.txt

RUN python -m pip install --no-cache-dir -i https://pypi.tuna.tsinghua.edu.cn/simple -r /app/requirements.txt

COPY workers/func1-python/src /app/src

CMD ["python", "-m", "src.main"]
