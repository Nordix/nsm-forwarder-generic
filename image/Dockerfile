FROM alpine:latest
RUN apk add jq
COPY --chown=0:0 default/ /
CMD ["/bin/nsm-forwarder-generic"]
