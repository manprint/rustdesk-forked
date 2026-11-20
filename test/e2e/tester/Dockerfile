FROM python:3.13-slim
RUN pip install --no-cache-dir grpcio-tools==1.71.0 websockets==15.0.1
WORKDIR /app
COPY server/libs/hbb_common/protos/rendezvous.proto /proto/
RUN python -m grpc_tools.protoc -I/proto --python_out=/app /proto/rendezvous.proto
COPY test/e2e/tester/e2e.py /app/e2e.py
ENTRYPOINT ["python", "-u", "e2e.py"]
