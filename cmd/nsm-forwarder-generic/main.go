// Copyright (c) 2020 Cisco and/or its affiliates.
//
// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at:
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// +build linux

package main

import (
	"context"
	"net/url"
	"os"
	"fmt"
	"path/filepath"
	"time"
	"encoding/json"
	"os/exec"

	"github.com/edwarnicke/grpcfd"
	"github.com/edwarnicke/signalctx"
	"github.com/golang/protobuf/ptypes"
	"github.com/kelseyhightower/envconfig"
	"github.com/sirupsen/logrus"
	"github.com/spiffe/go-spiffe/v2/spiffetls/tlsconfig"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"github.com/golang/protobuf/ptypes/empty"

	registryapi "github.com/networkservicemesh/api/pkg/api/registry"
	"github.com/networkservicemesh/sdk/pkg/networkservice/common/authorize"
	registryinterpose "github.com/networkservicemesh/sdk/pkg/registry/common/interpose"
	registryrefresh "github.com/networkservicemesh/sdk/pkg/registry/common/refresh"
	registrysendfd "github.com/networkservicemesh/sdk/pkg/registry/common/sendfd"
	registrychain "github.com/networkservicemesh/sdk/pkg/registry/core/chain"
	"github.com/networkservicemesh/sdk/pkg/tools/grpcutils"
	"github.com/networkservicemesh/sdk/pkg/tools/spiffejwt"

	"github.com/networkservicemesh/sdk/pkg/networkservice/chains/endpoint"
	"github.com/networkservicemesh/api/pkg/api/networkservice"
	"github.com/networkservicemesh/sdk/pkg/networkservice/core/next"

	"github.com/networkservicemesh/sdk/pkg/networkservice/utils/metadata"
	"github.com/networkservicemesh/sdk/pkg/networkservice/common/mechanisms/recvfd"
	"github.com/networkservicemesh/sdk/pkg/networkservice/common/clienturl"
	"github.com/networkservicemesh/sdk/pkg/networkservice/common/connect"
	"github.com/networkservicemesh/sdk/pkg/networkservice/common/mechanismtranslation"
	"github.com/networkservicemesh/sdk/pkg/networkservice/chains/client"
	"github.com/networkservicemesh/sdk/pkg/networkservice/common/mechanisms/sendfd"
	"github.com/networkservicemesh/sdk/pkg/networkservice/common/mechanisms"
	"github.com/networkservicemesh/api/pkg/api/networkservice/mechanisms/kernel"
	"github.com/networkservicemesh/api/pkg/api/networkservice/mechanisms/cls"

)

// Config - configuration for cmd-forwarder-vpp
type Config struct {
	Name             string        `default:"forwarder" desc:"Name of Endpoint"`
	NSName           string        `default:"xconnectns" desc:"Name of Network Service to Register with Registry"`
	ConnectTo        url.URL       `default:"unix:///connect.to.socket" desc:"url to connect to" split_words:"true"`
	MaxTokenLifetime time.Duration `default:"24h" desc:"maximum lifetime of tokens" split_words:"true"`
}

var version = "unknown"

func main() {
	starttime := time.Now()
	fmt.Printf("Version [%s]\n", version)

	// setup context to catch signals
	ctx := signalctx.WithSignals(context.Background())
	ctx, cancel := context.WithCancel(ctx)

	// get config from environment
	config := &Config{}
	if err := envconfig.Process("nsm", config); err != nil {
		logrus.Fatalf("error processing config from env: %+v", err)
	}
	logrus.Infof("Config read")

	// retrieving svid
	logrus.Infof("SPIFFE_ENDPOINT_SOCKET=%s", os.Getenv("SPIFFE_ENDPOINT_SOCKET"))
	source, err := workloadapi.NewX509Source(ctx)
	if err != nil {
		logrus.Fatalf("error getting x509 source: %+v", err)
	}
	logrus.Infof("Got a X509Source")
	svid, err := source.GetX509SVID()
	if err != nil {
		logrus.Fatalf("error getting x509 svid: %+v", err)
	}
	logrus.Infof("SVID: %q", svid.ID)

	// Creds
	clientCreds := grpcfd.TransportCredentials(credentials.NewTLS(tlsconfig.MTLSClientConfig(source, source, tlsconfig.AuthorizeAny())))
	serverCreds := grpcfd.TransportCredentials(credentials.NewTLS(tlsconfig.MTLSServerConfig(source, source, tlsconfig.AuthorizeAny())))

	registryCC, err := grpc.DialContext(ctx,
		config.ConnectTo.String(),
		grpc.WithTransportCredentials(clientCreds),
		grpc.WithBlock(),
	)
	if err != nil {
		logrus.Fatalf("failed to create registryCC: %+v", err)
	}

	// create xconnect network service endpoint
	tokenGenerator := spiffejwt.TokenGeneratorFunc(source, config.MaxTokenLifetime)
	endpoint := endpoint.NewServer(
		ctx, config.Name, authorize.NewServer(), tokenGenerator,
		&calloutServer{ id : "endpoint"},
		metadata.NewServer(),
		recvfd.NewServer(),
		// Statically set the url we use to the unix file socket for the NSMgr
		clienturl.NewServer(&config.ConnectTo),
		connect.NewServer(
			ctx,
			client.NewClientFactory(
				config.Name,
				// What to call onHeal
				//addressof.NetworkServiceClient(adapters.NewServerToClient(rv)),
				nil,
				tokenGenerator,
				mechanismtranslation.NewClient(),
				// mechanisms
				&mechanismClient{ id : "kernel"},
				recvfd.NewClient(),
			),
			grpc.WithTransportCredentials(clientCreds),
			grpc.WithDefaultCallOptions(grpc.WaitForReady(true)),
		),

		mechanisms.NewServer(map[string]networkservice.NetworkServiceServer{
			kernel.MECHANISM: &calloutServer{ id : "mechanism"},
		}),

		sendfd.NewServer(),
	)

	// create grpc server and register xconnect
	server := grpc.NewServer(grpc.Creds(serverCreds))
	endpoint.Register(server)
	listenOn := &(url.URL{Scheme: "unix", Path: filepath.Join("/var/lib/networkservicemesh", config.Name)})
	srvErrCh := grpcutils.ListenAndServe(ctx, listenOn, server)
	exitOnErrCh(ctx, cancel, srvErrCh)
	logrus.Infof("Listen on %s", listenOn.String())

	// register with the registry
	logrus.Infof("NSM: Connecting to NSE registry %v", config.ConnectTo.String())
	registryClient := registrychain.NewNetworkServiceEndpointRegistryClient(
		registryinterpose.NewNetworkServiceEndpointRegistryClient(),
		registryrefresh.NewNetworkServiceEndpointRegistryClient(),
		registrysendfd.NewNetworkServiceEndpointRegistryClient(),
		registryapi.NewNetworkServiceEndpointRegistryClient(registryCC),
	)
	// TODO - something smarter for expireTime
	expireTime, err := ptypes.TimestampProto(time.Now().Add(config.MaxTokenLifetime))
	if err != nil {
		logrus.Fatalf("failed to connect to registry: %+v", err)
	}
	_, err = registryClient.Register(ctx, &registryapi.NetworkServiceEndpoint{
		Name:                config.Name,
		NetworkServiceNames: []string{config.NSName},
		Url:                 listenOn.String(),
		ExpirationTime:      expireTime,
	})
	if err != nil {
		logrus.Fatalf("failed to connect to registry: %+v", err)
	}

	logrus.Infof("Startup completed in %v", time.Since(starttime))

	// TODO - cleaner shutdown across these three channels
	<-ctx.Done()
	<-srvErrCh
}

func exitOnErrCh(ctx context.Context, cancel context.CancelFunc, errCh <-chan error) {
	// If we already have an error, log it and exit
	select {
	case err := <-errCh:
		logrus.Fatal(err)
	default:
	}
	// Otherwise wait for an error in the background to log and cancel
	go func(ctx context.Context, errCh <-chan error) {
		err := <-errCh
		logrus.Error(err)
		cancel()
	}(ctx, errCh)
}

type calloutServer struct {
	id string
}

func (s *calloutServer) Request(
	ctx context.Context, request *networkservice.NetworkServiceRequest) (*networkservice.Connection, error) {

	if request.MechanismPreferences != nil {
		ctx = context.WithValue(ctx, "MechanismPreferences", request.MechanismPreferences)
	}

	//logrus.Infof("calloutServer(%s); request=%+v", s.id, request)
	conn, err := next.Server(ctx).Request(ctx, request)
	//logrus.Infof("calloutServer(%s); conn=%+v, err=%v", s.id, conn, err)

	// Add our own ip to a remote mechanism
	if s.id == "mechanism" {
		if conn.Mechanism != nil {
			if conn.Mechanism.Cls == cls.REMOTE {
				conn.Mechanism.Parameters["dst_ip"] = os.Getenv("POD_IP")
			}
		} else {
			// (can conn.Mechanism ever be nil?)
			conn.Mechanism = &networkservice.Mechanism{
				Cls:        cls.REMOTE,
				Type:       kernel.MECHANISM,
				Parameters: map[string]string{
					"dst_ip": os.Getenv("POD_IP"),
				},
			}
		}
	}

	return conn, err
}
func (s *calloutServer) Close(
	ctx context.Context, conn *networkservice.Connection) (*empty.Empty, error) {
	logrus.Infof("calloutServer(%s); close=%+v", s.id, conn)
	return next.Server(ctx).Close(ctx, conn)
}

type mechanismClient struct {
	id string
}
func (k *mechanismClient) Request(
	ctx context.Context, request *networkservice.NetworkServiceRequest, opts ...grpc.CallOption) (*networkservice.Connection, error) {
/*
	local := &networkservice.Mechanism{
		Cls:        cls.LOCAL,
		Type:       kernel.MECHANISM,
		Parameters: map[string]string{},
	}
	remote := &networkservice.Mechanism{
		Cls:        cls.REMOTE,
		Type:       kernel.MECHANISM,
		Parameters: map[string]string{
			"src_ip": os.Getenv("POD_IP"),
		},
	}
	request.MechanismPreferences = append(request.MechanismPreferences, local, remote)
*/
	var err error
	var conn *networkservice.Connection
	request.MechanismPreferences, err = mechanismCallout(ctx)
	if err != nil {
		logrus.Infof("mechanismCallout err %v", err)
	}
	conn, err = next.Client(ctx).Request(ctx, request, opts...)
	mechanismPreferences := ctx.Value("MechanismPreferences").([]*networkservice.Mechanism)
	err = requestCallout(
		ctx, &networkservice.NetworkServiceRequest{
			Connection : conn,
			MechanismPreferences : mechanismPreferences,
		})
	if err != nil {
		logrus.Infof("requestCallout err %v", err)
	}
	return conn, err
}

func (k *mechanismClient) Close(
	ctx context.Context, conn *networkservice.Connection, opts ...grpc.CallOption) (*empty.Empty, error) {
	return next.Client(ctx).Close(ctx, conn, opts...)
}


// ----------------------------------------------------------------------
// Callout functions

func calloutProgram() string {
	forwarder := os.Getenv("FORWARDER")
	if forwarder == "" {
		forwarder = "/bin/forwarder.sh"
	}
	return forwarder
}

// Send the Request in json format on stdin to the callout script 
func requestCallout(ctx context.Context, req *networkservice.NetworkServiceRequest) error {
	logrus.Infof("requestCallout")
	cmd := exec.Command(calloutProgram(), "request")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	enc := json.NewEncoder(stdin)
	go func() {
		defer stdin.Close()
		_ = enc.Encode(req)
	}()
	if out, err := cmd.Output(); err != nil {
		return err
	} else {
		fmt.Println(string(out))
	}
	return nil
}

// Expect a Mechanism array in json format on stdout from the callout script
func mechanismCallout(ctx context.Context) ([]*networkservice.Mechanism, error) {
	logrus.Infof("mechanismCallout")
	cmd := exec.Command(calloutProgram(), "mechanism")
	out, err := cmd.Output()
	if err != nil {
		logrus.Infof("mechanismCallout err %v", err)
		return nil, err
	}
	fmt.Println(string(out))

	var m []*networkservice.Mechanism
	err = json.Unmarshal(out, &m)
	if err != nil {
		logrus.Infof("mechanismCallout Unmarshal err %v", err)
		return nil, err
	}
	return m, nil
}
