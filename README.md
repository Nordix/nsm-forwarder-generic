# nsm-forwarder-generic

A generic forwarder for NSM next-gen.

This forwarder was created for educational and experimental
purposes. It makes callouts to a script/program that will do the
necessary network setup. This makes it easy to make a PoC for a new
forwarder before implementing the real one.



## Local

Sequence diagram when the `nsc` and `nse` are on the same node;

<img src="seq-local.svg" alt="Local setup" width="40%" />


Request (narrowed);
```json
{
  "connection": {
    "id": "f8eca5d3-d1d1-4ef2-8616-b2e45951d346",
    "network_service": "icmp-responder",
    "mechanism": {
      "cls": "LOCAL",
      "type": "KERNEL",
      "parameters": {
        "inodeURL": "file:///proc/20/fd/14"
      }
    },
    "context": {
      "ip_context": {
        "src_ip_addr": "169.254.0.1/32",
        "dst_ip_addr": "169.254.0.0/32",
        "src_routes": [
          {
            "prefix": "169.254.0.0/32"
          }
        ],
        "dst_routes": [
          {
            "prefix": "169.254.0.1/32"
          }
        ]
      }
    }
  },
  "mechanism_preferences": [
    {
      "cls": "LOCAL",
      "type": "KERNEL",
      "parameters": {
        "inodeURL": "file:///proc/20/fd/11",
        "name": "nsm-1"
      }
    }
  ]
}
```

The forwarder shall;

* Create two interfaces connected to each other

* Inject one to the nsc and the other to the nse

* Set addresses on the interfaces and add routes

The obvious choice for Linux is a veth pair. The "inodeURL"s are used
to get the netns of the PODs.


## Remote

Sequence diagram when the `nsc` and `nse` are on different nodes;

<img src="seq-remote.svg" alt="Remote setup" width="60%" />

Communication is setup and interfaces injected by the callout script
in the "request" callout.

Remote request (narrowed);
```json
{
  "connection": {
    "id": "0bb3f086-717a-48b9-87d8-33d95362ffe4",
    "network_service": "icmp-responder",
    "mechanism": {
      "cls": "LOCAL",
      "type": "KERNEL",
      "parameters": {
        "inodeURL": "file:///proc/19/fd/12"
      }
    },
    "context": {
      "ip_context": {
        "src_ip_addr": "169.254.0.1/32",
        "dst_ip_addr": "169.254.0.0/32",
        "src_routes": [
          {
            "prefix": "169.254.0.0/32"
          }
        ],
        "dst_routes": [
          {
            "prefix": "169.254.0.1/32"
          }
        ]
      }
    }
  },
  "mechanism_preferences": [
    {
      "cls": "REMOTE",
      "type": "KERNEL",
      "parameters": {
        "src_ip": "192.168.1.2",
        "vlan": "3877",
        "vni": "1223869"
      }
    }
  ]
}
```

Local request (narrowed);
```json
{
  "connection": {
    "id": "71f46233-821d-4d3c-86f5-059c3f5917d3",
    "network_service": "icmp-responder",
    "mechanism": {
      "cls": "REMOTE",
      "type": "KERNEL",
      "parameters": {
        "dst_ip": "192.168.1.3",
        "src_ip": "192.168.1.2",
        "vlan": "3877",
        "vni": "1223869"
      }
    },
    "context": {
      "ip_context": {
        "src_ip_addr": "169.254.0.1/32",
        "dst_ip_addr": "169.254.0.0/32",
        "src_routes": [
          {
            "prefix": "169.254.0.0/32"
          }
        ],
        "dst_routes": [
          {
            "prefix": "169.254.0.1/32"
          }
        ]
      }
    },
  "mechanism_preferences": [
    {
      "cls": "LOCAL",
      "type": "KERNEL",
      "parameters": {
        "inodeURL": "file:///proc/21/fd/11",
        "name": "nsm-1"
      }
    }
  ]
}
```

The `machanism` is always "KERNEL" since NSM must be updated if other
types like "VLAN" or "OVS" shall be supported. The callout script adds
the ip of the "other" nsmgr and random values for "vlan" and "vni".

**NOTE** there is a chance that vlan or vni will collide, but hey,
  this for experiments only.




## Build image

```
./build.sh image
# Upload to xcluster local registry
images lreg_upload --strip-host registry.nordix.org/cloud-native/nsm/forwarder-generic:latest
```

## Extension

The callout script can be switched to a script which creates VLAN interface and inject it into the `nsc`. An `eth2` interface is required to be set on the node.

```
# Set a convenient network topology - eth2 interface needed
export XOVLS="private-reg network-topology"
export TOPOLOGY=multilan
. $(xc ovld network-topology)/$TOPOLOGY/Envsettings

# Start the generic forwarder with vlan
export xcluster_NSM_FORWARDER=generic-vlan
xcadmin k8s_test --no-stop nsm basic_nextgen > $log
```
