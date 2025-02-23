FROM golang:alpine3.21 AS binary
ADD whoami.go /app/
WORKDIR /app
RUN go mod init whoami && \
    go build

FROM alpine:3.21
WORKDIR /app
ENV PORT=8000
EXPOSE 8000
COPY --from=binary /app/whoami /app
RUN apk add --no-cache curl
CMD ["/app/whoami"]