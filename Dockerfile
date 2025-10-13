# syntax=docker/dockerfile:1.4
FROM golang:1.21-alpine AS builder
WORKDIR /src
COPY . .
RUN apk add --no-cache build-base && \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -extldflags '-static'" -o /out/trafficjam ./cmd/trafficjam

FROM scratch
COPY --from=builder /out/trafficjam /trafficjam
ENTRYPOINT ["/trafficjam"]
