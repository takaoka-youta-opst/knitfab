package hook_test

import (
	"errors"
	"testing"

	"github.com/opst/knitfab/cmd/loops/hook"
	"github.com/opst/knitfab/pkg/configs/watcher"
)

func TestWatcher(t *testing.T) {

	beforePayload := "before payload"
	beforeErr := errors.New("before error")

	afterPayload := "after payload"
	afterErr := errors.New("after error")

	funcWatcherHasBeenInvoked := false
	testee := hook.Watch(watcher.NewFuncWatcher(func() (hook.Hook[string], error) {
		funcWatcherHasBeenInvoked = true
		return hook.Func[string]{
			BeforeFn: func(v string) error {
				if v != beforePayload {
					t.Errorf("expected %s, but got %s", beforePayload, v)
				}
				return beforeErr
			},
			AfterFn: func(v string) error {
				if v != afterPayload {
					t.Errorf("expected %s, but got %s", afterPayload, v)
				}
				return afterErr
			},
		}, nil
	}))

	funcWatcherHasBeenInvoked = false
	if err := testee.Before(beforePayload); !errors.Is(err, beforeErr) {
		t.Errorf("expected %v, but got %v", beforeErr, err)
	}
	if !funcWatcherHasBeenInvoked {
		t.Error("expected func watcher to be invoked")
	}

	funcWatcherHasBeenInvoked = false
	if err := testee.After(afterPayload); !errors.Is(err, afterErr) {
		t.Errorf("expected %v, but got %v", afterErr, err)
	}
	if !funcWatcherHasBeenInvoked {
		t.Error("expected func watcher to be invoked")
	}
}
