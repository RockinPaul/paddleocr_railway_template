"""One throwaway OCR request, run at startup before the proxy opens.

Downloading the weights is only half the cold start: the first inference also
loads them into memory and initialises Paddle's executor. Measured locally at
98 seconds versus roughly 4 for every request after it.
"""
import base64
import json
import sys
import urllib.request

port = sys.argv[1]
with open("/opt/warmup.png", "rb") as fh:
    payload = json.dumps(
        {"file": base64.b64encode(fh.read()).decode(), "fileType": 1}
    ).encode()

request = urllib.request.Request(
    f"http://127.0.0.1:{port}/ocr",
    data=payload,
    headers={"Content-Type": "application/json"},
)
urllib.request.urlopen(request, timeout=600).read()
