package watcher

// Watcher is an interface that allows to watch for changes in a resource and get its current state.
type Watcher[T any] interface {
	// Get returns the current state of the resource.
	Get() (T, error)

	// Close stops the watcher.
	Close()
}
