package core

import "github.com/metacubex/mihomo/constant"

const defaultGeositeMode = geositeCompile

func MarkPacketTunnel() {
	geositeMode = geositeRewrite
}

func SetCacheFile(file string) {
	constant.SetCacheFile(file)
}
