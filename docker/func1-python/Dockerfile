FROM python:3.12-slim

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG ALL_PROXY
ARG NO_PROXY

ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY workers/func1-python/requirements.txt /app/requirements.txt

RUN HTTP_PROXY="${HTTP_PROXY}" \
    HTTPS_PROXY="${HTTPS_PROXY}" \
    ALL_PROXY="${ALL_PROXY}" \
    NO_PROXY="${NO_PROXY}" \
    http_proxy="${HTTP_PROXY}" \
    https_proxy="${HTTPS_PROXY}" \
    all_proxy="${ALL_PROXY}" \
    no_proxy="${NO_PROXY}" \
    python -m pip install --no-cache-dir -i https://mirrors.aliyun.com/pypi/simple/ -r /app/requirements.txt

COPY workers/func1-python/src /app/src

CMD ["python", "-m", "src.main"]
