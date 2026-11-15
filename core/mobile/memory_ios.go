package mobile

import "runtime/debug"

// GOMEMLIMIT cannot keep the extension under its jetsam limit: the runtime
// reads it while the extension loads, before any of the extension's code runs.
func SetMemoryLimit(limit int64) int64 {
	return debug.SetMemoryLimit(limit)
}
