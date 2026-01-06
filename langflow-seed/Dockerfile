FROM alpine:3.19

RUN adduser -D -u 10001 app
WORKDIR /seed

COPY langflow.db /seed/langflow.db
RUN chown -R app:app /seed

USER app
