FROM ghcr.io/liatrio/python:3.12-slim

ENV VERSION="0.3.2"

LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.description="Demo application"
LABEL org.opencontainers.image.authors="AutoGov"

RUN pip install --no-cache-dir Flask && \
    echo "from flask import Flask, os\napp = Flask(__name__)\n\n@app.route('/')\ndef test():\n    version = os.environ.get('VERSION', 'unknown')\n    return f'Demo application version {version}'\n\nif __name__ == '__main__':\n    app.run(host='0.0.0.0')" > /app.py

CMD ["python3", "/app.py"]
