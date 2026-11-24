FROM python:3.13-slim-bookworm@sha256:a5a7017efc5969e00ae2b91c8eb0631049a569652aa4ffc4501769049ae45c72
RUN pip install --no-cache-dir grpcio==1.76.0 PyJWT==2.10.1 cryptography==46.0.3
COPY fixture.py /fixture/fixture.py
USER 65532:65532
ENTRYPOINT ["python", "-B", "/fixture/fixture.py"]
