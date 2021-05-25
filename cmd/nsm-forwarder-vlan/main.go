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
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"time"

	nested "github.com/antonfisher/nested-logrus-formatter"

	"github.com/edwarnicke/grpcfd"
	"github.com/edwarnicke/signalctx"
	"github.com/golang/protobuf/ptypes"
	"github.com/kelseyhightower/envconfig"
	"github.com/networkservicemesh/sdk/pkg/tools/log"
	"github.com/networkservicemesh/sdk/pkg/tools/log/logruslogger"
	"github.com/sirupsen/logrus"
	"github.com/spiffe/go-spiffe/v2/spiffetls/tlsconfig"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"

	registryapi "github.com/networkservicemesh/api/pkg/api/registry"
	"github.com/networkservicemesh/sdk/pkg/networkservice/common/authorize"
	registryclient "github.com/networkservicemesh/sdk/pkg/registry/chains/client"
	"github.com/networkservicemesh/sdk/pkg/tools/grpcutils"
	"github.com/networkservicemesh/sdk/pkg/tools/spiffejwt"

	"github.com/networkservicemesh/sdk-kernel/pkg/kernel/networkservice/chains/xconnectns"
)

// Config - configuration for cmd-forwarder-vlan
type Config struct {
	Name             string            `default:"forwarder" desc:"Name of Endpoint"`
	NSName           string            `default:"xconnectns" desc:"Name of Network Service to Register with Registry"`
	ConnectTo        url.URL           `default:"unix:///connect.to.socket" desc:"url to connect to" split_words:"true"`
	MaxTokenLifetime time.Duration     `default:"24h" desc:"maximum lifetime of tokens" split_words:"true"`
	Labels           map[string]string `default:"" desc:"Endpoint labels"`
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

	// ********************************************************************************
	// setup logging
	// ********************************************************************************
	logrus.SetFormatter(&nested.Formatter{})
	logrus.SetLevel(logrus.DebugLevel)
	log.EnableTracing(true)
	ctx = log.WithFields(ctx, map[string]interface{}{"cmd": os.Args[0]})
	ctx = log.WithLog(ctx, logruslogger.New(ctx))

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
	endpoint := xconnectns.NewServer(
		ctx,
		config.Name,
		authorize.NewServer(),
		spiffejwt.TokenGeneratorFunc(source, config.MaxTokenLifetime),
		&config.ConnectTo,
		grpc.WithTransportCredentials(clientCreds),
		grpc.WithDefaultCallOptions(
			grpc.WaitForReady(true),
			//grpc.PerRPCCredentials(token.NewPerRPCCredentials(spiffejwt.TokenGeneratorFunc(source, config.MaxTokenLifetime))),
		),
		//grpcfd.WithChainStreamInterceptor(),
		//grpcfd.WithChainUnaryInterceptor(),
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

	registryClient := registryclient.NewNetworkServiceEndpointRegistryInterposeClient(ctx, registryCC)

	// TODO - something smarter for expireTime
	expireTime, err := ptypes.TimestampProto(time.Now().Add(config.MaxTokenLifetime))
	if err != nil {
		logrus.Fatalf("failed to connect to registry: %+v", err)
	}
	_, err = registryClient.Register(ctx, &registryapi.NetworkServiceEndpoint{
		Name:                config.Name,
		NetworkServiceNames: []string{config.NSName},
		NetworkServiceLabels: map[string]*registryapi.NetworkServiceLabels{
			config.NSName: {
				Labels: config.Labels,
			},
		},
		Url:            listenOn.String(),
		ExpirationTime: expireTime,
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
