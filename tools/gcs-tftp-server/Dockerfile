# Stage 1: Build static Go binary
FROM --platform=$BUILDPLATFORM golang:1.22-alpine AS builder
ARG TARGETOS=linux
ARG TARGETARCH=amd64

WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/gcs-tftp-server main.go

# Stage 2: Minimal distroless runtime (includes CA certificates for HTTPS to GCS)
FROM gcr.io/distroless/static-debian12:latest
LABEL org.opencontainers.image.source="https://github.com/affordablemobiles/glazier-starter-kit"
LABEL org.opencontainers.image.description="Stateless Google Cloud Storage TFTP Relay for iPXE Network Boot"
LABEL org.opencontainers.image.licenses="Apache-2.0"

COPY --from=builder /out/gcs-tftp-server /gcs-tftp-server

ENV GCS_BUCKET="" \
    GCS_PREFIX="" \
    TFTP_LISTEN=":69" \
    TFTP_SINGLE_PORT="true" \
    CACHE_TTL="5m"

EXPOSE 69/udp
ENTRYPOINT ["/gcs-tftp-server"]
