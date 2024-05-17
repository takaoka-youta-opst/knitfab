//go:generate go run github.com/Songmu/gocredits/cmd/gocredits@v0.3.0 -w
package main

import (
	"context"
	_ "embed"
	"errors"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/opst/knitfab/cmd/loops/hook"
	"github.com/opst/knitfab/cmd/loops/recurring"
	knit "github.com/opst/knitfab/pkg"
	"github.com/opst/knitfab/pkg/api/types/runs"
	configs "github.com/opst/knitfab/pkg/configs/backend"
	cfg_hook "github.com/opst/knitfab/pkg/configs/hook"
	"github.com/opst/knitfab/pkg/configs/watcher"
	kdb "github.com/opst/knitfab/pkg/db"
	kpg "github.com/opst/knitfab/pkg/db/postgres"
	"github.com/opst/knitfab/pkg/kubeutil"
	"github.com/opst/knitfab/pkg/utils/args"

	"github.com/opst/knitfab/pkg/utils/try"
	"github.com/opst/knitfab/pkg/workloads/k8s"
)

//go:embed CREDITS
var CREDITS string

func main() {
	logger := log.Default()
	ctx, cancel := signal.NotifyContext(
		context.Background(), os.Interrupt, os.Kill, syscall.SIGTERM,
	)
	// call cancel() when this function exits
	defer cancel()

	// define command line flags
	//-- path to config file
	pconfig := flag.String(
		"config", os.Getenv("KNIT_BACKEND_CONFIG"), "path to config file",
	)
	phooks := flag.String(
		"hooks", os.Getenv("KNIT_HOOK_CONFIG"), "path to hook config file",
	)
	//-- which loop type to run
	loopType := args.Parser(kdb.AsLoopType)
	flag.Var(loopType, "type", "one of loop type")
	//-- loop policy
	policy := args.Parser(recurring.ParsePolicy)
	flag.Var(
		policy, "policy",
		`loop policy (syntax: forever[:COOLDOWN]|backlog).`+
			` "forever[:COOLDOWN]" = run forever until error. When backlog is over, `+
			`wait COOLDOWN (optional duration. default: 0) as inteval.`+
			` "backlog" = run until error or backlog is over.`,
	)
	plic := flag.Bool("license", false, "show licenses of dependencies")
	// parse command line flags
	flag.Parse()

	if *plic {
		logger.Println(CREDITS)
		return
	}

	conf := try.To(configs.LoadBackendConfig(*pconfig)).OrFatal(logger)
	kclientset := kubeutil.ConnectToK8s()

	kcluster := knit.AttachKnitCluster(
		kclientset,
		conf.Cluster(),
		try.To(kpg.New(ctx, conf.Cluster().Database())).OrFatal(logger),
	)

	var hooks hook.Hook[runs.Detail] = hook.None[runs.Detail]{}
	if hookPath := *phooks; hookPath != "" {
		w := try.To(watcher.NewFileWatcher(*phooks, func(configFile string) (hook.Hook[runs.Detail], error) {
			cfg, err := cfg_hook.Load(configFile)
			logger.Printf("loading hook config from %s", configFile)
			if err != nil {
				return nil, err
			}
			return hook.Build(cfg.Lifecycle), nil
		})).OrFatal(logger)
		hooks = hook.Watch(w)
	}

	logger.Printf(
		`start loop "%s" /w policy "%s"`,
		loopType.Value().String(), policy.Value().String(),
	)

	err := StartLoop(
		ctx, logger, kcluster, k8s.WrapK8sClient(kclientset),
		LoopManifest{
			Type:   loopType.Value(),
			Policy: recurring.UntilError(policy.Value()),
			Hooks:  hooks,
		},
	)

	if err == nil || errors.Is(err, context.Canceled) {
		return
	}

	if ctx.Err() != nil {
		logger.Fatal(err, "(loop context is cancelled by:", context.Cause(ctx), ")")
	} else {
		logger.Fatal(err)
	}
}
