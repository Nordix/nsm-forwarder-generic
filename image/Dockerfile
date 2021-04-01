FROM alpine:latest
ARG FORWARDER=forwarder-generic
RUN apk add jq openvswitch net-tools iproute2 util-linux
COPY --chown=0:0 default/ /
COPY --chown=0:0 default/bin/nsm-$FORWARDER /bin/nsm-forwarder
CMD ["/bin/nsm-forwarder"]
