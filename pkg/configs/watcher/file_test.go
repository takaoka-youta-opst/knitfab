package watcher_test

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/opst/knitfab/pkg/configs/watcher"
	"github.com/opst/knitfab/pkg/utils/try"
)

func TestFileWatcher_Modified(t *testing.T) {

	deadlineCh := make(<-chan time.Time)
	{
		if deadline, ok := t.Deadline(); ok {
			deadlineCh = time.After(time.Until(deadline) - 1*time.Second)
		}
	}

	dir := t.TempDir()
	file := filepath.Join(dir, "file")
	try.To(os.Create(file)).OrFatal(t)

	loader := func(f string) (string, error) {
		b, err := os.ReadFile(f)
		return string(b), err
	}

	w := try.To(watcher.NewFileWatcher(file, loader)).OrFatal(t)
	defer w.Close()

	{
		want := ""
		got := try.To(w.Get()).OrFatal(t)
		if got != want {
			t.Fatalf("expected empty content, but got <%s>", got)
		}
	}

	{
		want := "hello"
		if err := os.WriteFile(file, []byte(want), 0644); err != nil {
			t.Fatal(err)
		}

		got := try.To(w.Get()).OrFatal(t)
	WAIT:
		for {
			select {
			case <-deadlineCh:
				break WAIT
			case <-time.After(10 * time.Millisecond):
				// pass
			}
			got = try.To(w.Get()).OrFatal(t)
			if got == want {
				return
			}
		}
		t.Fatalf("want %s. but got %s", want, got)
	}
}
