package hook

import "github.com/opst/knitfab/pkg/configs/watcher"

type HookWatcher[T any] struct {
	Watcher watcher.Watcher[Hook[T]]
}

func Watch[T any](w watcher.Watcher[Hook[T]]) HookWatcher[T] {
	return HookWatcher[T]{Watcher: w}
}

func (h HookWatcher[T]) Before(v T) error {
	hook, err := h.Watcher.Get()
	if err != nil {
		return err
	}
	return hook.Before(v)
}

func (h HookWatcher[T]) After(v T) error {
	hook, err := h.Watcher.Get()
	if err != nil {
		return err
	}
	return hook.After(v)
}

func (h HookWatcher[T]) Close() {
	h.Watcher.Close()
}
