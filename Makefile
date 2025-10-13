BINARY=trafficjam
GOFLAGS=-trimpath -ldflags="-s -w -extldflags '-static'"

.PHONY: all build clean docker lint test

all: build

build:
	CGO_ENABLED=0 go build $(GOFLAGS) -o bin/$(BINARY) ./cmd/trafficjam

clean:
	rm -rf bin/

lint:
	golangci-lint run

test:
	go test ./...

docker:
	docker build -t trafficjam .
