ARG DOCKER_IMAGE_PREFIX=docker.io
FROM ${DOCKER_IMAGE_PREFIX}/library/python:3.14.4-slim

ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY workers/func1-python/requirements.txt /app/requirements.txt

RUN python -m pip install --no-cache-dir -i https://mirrors.aliyun.com/pypi/simple/ -r /app/requirements.txt

COPY workers/func1-python/src /app/src

CMD ["python", "-m", "src.main"]
