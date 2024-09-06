FROM python:3.12-slim

RUN pip install --no-cache-dir Flask && \
    echo "from flask import Flask\napp = Flask(__name__)\n\n@app.route('/')\ndef test():\n    return 'test'\n\nif __name__ == '__main__':\n    app.run(host='0.0.0.0')" > /app.py

CMD ["python3", "/app.py"]
