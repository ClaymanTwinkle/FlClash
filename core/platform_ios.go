package core

import "github.com/metacubex/mihomo/constant"

const defaultGeositeMode = geositeCompile

var serveController = false

func MarkPacketTunnel() {
	geositeMode = geositeRewrite
	serveController = true
}

func SetCacheFile(file string) {
	constant.SetCacheFile(file)
}
