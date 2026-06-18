# public stock python so external consumers can build without liatrio registry auth
FROM python:3.13-slim

# apply latest os security patches and upgrade pip (mirrors the prior base image)
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    pip install --no-cache-dir --upgrade pip

# non-root user previously provided by the base image
RUN useradd -m -u 1000 -s /bin/bash appuser
WORKDIR /app

ENV VERSION="0.21.0"

LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.description="Dedicated reusable automated governance workflows for internal Liatrio use."
LABEL org.opencontainers.image.authors="AutoGov"

USER root
RUN pip install --no-cache-dir Flask && \
    echo "from flask import Flask, os\napp = Flask(__name__)\n\n@app.route('/')\ndef test():\n    version = os.environ.get('VERSION', 'unknown')\n    return f'Demo application version {version}'\n\nif __name__ == '__main__':\n    app.run(host='0.0.0.0')" > /app.py
USER appuser

CMD ["python3", "/app.py"]

