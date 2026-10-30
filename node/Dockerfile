FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN go test ./... && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /seqpoint-node .
RUN mkdir -p /runtime/data && chown 65532:65532 /runtime/data

FROM scratch
COPY --from=build /seqpoint-node /seqpoint-node
COPY --from=build --chown=65532:65532 /runtime/data /data
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/seqpoint-node"]
