package core

const defaultGeositeMode = geositeCompile

// MarkPacketTunnel is called by the packet tunnel before its first setup, so
// its Core reads the rule-sets the app's Core compiled instead of GeoSite.
func MarkPacketTunnel() {
	geositeMode = geositeRewrite
}
