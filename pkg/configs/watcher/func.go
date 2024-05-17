package watcher

type FuncWatcher[T any] func() (T, error)

func NewFuncWatcher[T any](f func() (T, error)) FuncWatcher[T] {
	return f
}

func (w FuncWatcher[T]) Get() (T, error) {
	return w()
}

func (w FuncWatcher[T]) Close() {
}
