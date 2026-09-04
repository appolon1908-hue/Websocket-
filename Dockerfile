FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY cmd ./cmd
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /gateway ./cmd/gateway

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /gateway /gateway
USER 65532:65532
ENTRYPOINT ["/gateway"]
