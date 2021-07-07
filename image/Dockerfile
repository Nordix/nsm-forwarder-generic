FROM golang:1.16.3-alpine as build
ENV PATH ${PATH}:/usr/local/go/bin
ENV GO111MODULE=on
ENV CGO_ENABLED=0
ENV GOBIN=/bin
RUN go get github.com/grpc-ecosystem/grpc-health-probe@v0.4.1


FROM alpine:latest as runtime
ARG FORWARDER=forwarder-generic
RUN apk add jq openvswitch net-tools iproute2 util-linux
COPY --chown=0:0 default/ /
COPY --chown=0:0 default/bin/nsm-$FORWARDER /bin/nsm-forwarder
COPY --from=build /bin/grpc-health-probe /bin/grpc-health-probe
CMD ["/bin/nsm-forwarder"]
