package watcher

import (
	"context"

	"github.com/fsnotify/fsnotify"
)

// FileWatcher is a Watcher that watches for changes in a file.
type FileWatcher[T any] struct {
	path      string
	loader    func(string) (T, error)
	lastState T
	lastError error
	watcher   *fsnotify.Watcher
	close     func()
}

// NewFileWatcher creates a new FileWatcher[T], compliant with the Watcher[T] interface.
//
// The FileWatcher will watch for changes in the file at the given path and reload the resource using the given loader function.
//
// FileWatcher will keep the last state of the resource and the last error that occurred while loading it.
//
// # Args
//
// - path: the path to the file to watch.
//
// - loader: a function that loads the resource from the file.
//
// # Returns
//
// - a new FileWatcher.
//
// - an error if the watcher could not be created.
func NewFileWatcher[T any](path string, loader func(string) (T, error)) (*FileWatcher[T], error) {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}
	w := &FileWatcher[T]{
		path:    path,
		loader:  loader,
		watcher: watcher,
	}

	// Load initial state
	val, err := loader(path)
	w.lastState = val
	w.lastError = err

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		defer watcher.Close()
		defer cancel()

		for {
			select {
			case <-ctx.Done():
				return
			case _, ok := <-watcher.Events:
				if !ok {
					return
				}
				val, err := loader(path)
				w.lastState = val
				w.lastError = err
			}
		}
	}()

	if err := watcher.Add(path); err != nil {
		return nil, err
	}

	w.close = cancel
	return w, nil
}

func (w *FileWatcher[T]) Get() (T, error) {
	return w.lastState, w.lastError
}

func (w *FileWatcher[T]) Close() {
	w.close()
}
