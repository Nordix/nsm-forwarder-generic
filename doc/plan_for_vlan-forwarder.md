# Plan to create a vlan-forwarder based on vpp-forwarder

## Objective

A possible way of implementing a vlan-forwarder based on vpp-forwader and the analysis of vpp-forwarder are summerized in this document.

## Code repositories

The code of vpp-forwarder is contained by the [cmd-vpp-forwarder][1] and [sdk-vpp][2] repositories.<br>
The initialization is implemented in `cmd-vpp-forwarder` :<br>
* reads the config,
* start vpp and connect to it,
* initialyzing an `xconnectns` service endpoint (see `cmd-forwarder-vpp/main.go`)

The service endpoint [xconnectns][3] is implemented in `sdk-vpp` by

```
sdk-vpp/pkg/networkservice/chains/xconnectns - package provides an endpoint implementing xconnectns.
```

## Interfaces, addresses and routes

To implement the configuration of a vlan interface the [vxlan][4] package can be a good example:

```
sdk-vpp/pkg/networkservice/mechanisms/vxlan - provides networkservice.NetworkService{Client,Server} chain elements for the vxlan mechanism;
```

The vxlan configuration part is completed by the [up][5] package:

```
sdk-vpp/pkg/networkservice/up - provides chain elements to 'up' interfaces (and optionally wait for them to come up)
```

In addition to the above the `ipaddress` and `routes` packages together with [connectioncontextkernel][6] can be good starting points:

```
networkservice/connectioncontextkernel/ipcontext/ipaddress - provides networkservice chain elements that support setting ip addresses on kernel interfaces
networkservice/connectioncontextkernel/ipcontext/routes - provides a NetworkServiceServer that sets the routes in the kernel from the connection context
``` 

[1]: <https://github.com/networkservicemesh/cmd-forwarder-vpp> "cmd-forwarder-vpp"
[2]: <https://github.com/networkservicemesh/sdk-vpp> "sdk-vpp"
[3]: <https://pkg.go.dev/github.com/networkservicemesh/sdk-vpp@v0.0.0-20210216095703-ce9d2df4a513/pkg/networkservice/chains/xconnectns> "xconnectns"
[4]: <https://pkg.go.dev/github.com/networkservicemesh/sdk-vpp@v0.0.0-20210216095703-ce9d2df4a513/pkg/networkservice/mechanisms/vxlan> "vxlan"
[5]: <https://pkg.go.dev/github.com/networkservicemesh/sdk-vpp@v0.0.0-20210216095703-ce9d2df4a513/pkg/networkservice/up> "up"
[6]: <https://pkg.go.dev/github.com/networkservicemesh/sdk-vpp@v0.0.0-20210216095703-ce9d2df4a513/pkg/networkservice/connectioncontextkernel> "connectioncontextkernel"
