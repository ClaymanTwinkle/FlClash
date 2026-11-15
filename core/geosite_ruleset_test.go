package core

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/common/orderedmap"
	"github.com/metacubex/mihomo/component/geodata/router"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	rp "github.com/metacubex/mihomo/rules/provider"
)

func useGeositeMode(t *testing.T, mode geositeHandling) {
	t.Helper()
	previous := geositeMode
	geositeMode = mode
	t.Cleanup(func() { geositeMode = previous })
}

func useHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	previous := constant.Path.HomeDir()
	constant.SetHomeDir(home)
	t.Cleanup(func() { constant.SetHomeDir(previous) })
	return home
}

func policyKeys(policy *orderedmap.OrderedMap[string, any]) []string {
	var keys []string
	for pair := policy.Oldest(); pair != nil; pair = pair.Next() {
		keys = append(keys, pair.Key)
	}
	return keys
}

func rawWithDNS(rules []string, policy []string, filter []string) *config.RawConfig {
	raw := config.DefaultRawConfig()
	raw.Rule = rules
	raw.DNS.NameServerPolicy = orderedmap.New[string, any]()
	for _, key := range policy {
		raw.DNS.NameServerPolicy.Set(key, "223.5.5.5")
	}
	raw.DNS.FakeIPFilter = filter
	return raw
}

func TestGeositeCodesCollectsEveryConvertibleReference(t *testing.T) {
	raw := rawWithDNS(
		[]string{
			"GEOSITE,CN,DIRECT",
			"AND,((GEOSITE,google),(NETWORK,TCP)),g",
			"GEOSITE,category-ads-all@ads,REJECT",
			"DOMAIN,example.com,DIRECT",
		},
		[]string{"geosite:cn,private", "+.example.com"},
		[]string{"geosite:apple", "*.lan"},
	)
	raw.SubRules = map[string][]string{"sub": {"GEOSITE,netflix,g"}}

	got := geositeCodes(raw)

	want := []string{"apple", "cn", "google", "netflix", "private"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("codes = %v, want %v", got, want)
	}
}

func TestWriteGeositeSetSplitsDomainsFromKeywordsAndRegexes(t *testing.T) {
	dir := t.TempDir()
	domains := []*router.Domain{
		{Type: router.Domain_Domain, Value: "example.cn"},
		{Type: router.Domain_Full, Value: "exact.example.cn"},
		{Type: router.Domain_Plain, Value: "baidu"},
		{Type: router.Domain_Regex, Value: `^cn\d+\.example$`},
	}

	set, err := writeGeositeSet(dir, "cn", domains)

	if err != nil {
		t.Fatalf("writeGeositeSet = %v", err)
	}
	if set != (geositeSet{Domain: true, Extra: true}) {
		t.Errorf("set = %+v, want both halves", set)
	}
	mrs, err := os.ReadFile(filepath.Join(dir, "cn.mrs"))
	if err != nil {
		t.Fatalf("read mrs: %v", err)
	}
	var dumped bytes.Buffer
	if err := rp.ConvertToMrs(mrs, cp.Domain, cp.MrsRule, &dumped); err != nil {
		t.Fatalf("dump mrs: %v", err)
	}
	for _, want := range []string{"+.example.cn", "exact.example.cn"} {
		if !strings.Contains(dumped.String(), want) {
			t.Errorf("mrs %q lacks %q", dumped.String(), want)
		}
	}
	extra, err := os.ReadFile(filepath.Join(dir, "cn-extra.list"))
	if err != nil {
		t.Fatalf("read extra: %v", err)
	}
	if got, want := string(extra), "DOMAIN-KEYWORD,baidu\nDOMAIN-REGEX,^cn\\d+\\.example$\n"; got != want {
		t.Errorf("extra = %q, want %q", got, want)
	}
}

func TestRewriteGeositePointsRulesAndDnsAtTheCompiledSets(t *testing.T) {
	raw := rawWithDNS(
		[]string{
			"GEOSITE,cn,DIRECT",
			"AND,((GEOSITE,private),(NETWORK,UDP)),DIRECT",
			"NOT,((GEOSITE,cn)),g",
			"GEOSITE,google,g",
			"MATCH,g",
		},
		[]string{"geosite:cn,private", "+.example.com", "geosite:google"},
		[]string{"geosite:cn", "*.lan"},
	)
	sets := map[string]geositeSet{
		"cn":      {Domain: true, Extra: true},
		"private": {Domain: true},
	}

	rewriteGeosite(raw, sets)

	wantRules := []string{
		"RULE-SET,geosite-cn,DIRECT",
		"RULE-SET,geosite-cn-extra,DIRECT",
		"AND,((RULE-SET,geosite-private),(NETWORK,UDP)),DIRECT",
		"NOT,((GEOSITE,cn)),g",
		"GEOSITE,google,g",
		"MATCH,g",
	}
	if !reflect.DeepEqual(raw.Rule, wantRules) {
		t.Errorf("rules = %v, want %v", raw.Rule, wantRules)
	}
	wantPolicy := []string{"rule-set:geosite-cn,geosite-cn-extra,geosite-private", "+.example.com", "geosite:google"}
	if got := policyKeys(raw.DNS.NameServerPolicy); !reflect.DeepEqual(got, wantPolicy) {
		t.Errorf("nameserver-policy = %v, want %v", got, wantPolicy)
	}
	wantFilter := []string{"rule-set:geosite-cn", "rule-set:geosite-cn-extra", "*.lan"}
	if !reflect.DeepEqual(raw.DNS.FakeIPFilter, wantFilter) {
		t.Errorf("fake-ip-filter = %v, want %v", raw.DNS.FakeIPFilter, wantFilter)
	}
	wantProviders := map[string]string{
		"geosite-cn":       "./geosite/cn.mrs",
		"geosite-cn-extra": "./geosite/cn-extra.list",
		"geosite-private":  "./geosite/private.mrs",
	}
	if len(raw.RuleProvider) != len(wantProviders) {
		t.Errorf("rule-providers = %v, want %v", raw.RuleProvider, wantProviders)
	}
	for name, path := range wantProviders {
		if got := raw.RuleProvider[name]["path"]; got != path {
			t.Errorf("rule-providers[%s].path = %v, want %s", name, got, path)
		}
	}
}

func TestRewriteGeositeLeavesACodeWhoseRuleSetNameIsTaken(t *testing.T) {
	raw := rawWithDNS([]string{"GEOSITE,cn,DIRECT"}, nil, nil)
	raw.RuleProvider = map[string]map[string]any{"geosite-cn": {"type": "http"}}

	rewriteGeosite(raw, map[string]geositeSet{"cn": {Domain: true}})

	if !reflect.DeepEqual(raw.Rule, []string{"GEOSITE,cn,DIRECT"}) {
		t.Errorf("rules = %v, want the GEOSITE rule kept", raw.Rule)
	}
	if raw.RuleProvider["geosite-cn"]["type"] != "http" {
		t.Errorf("the profile's own geosite-cn was replaced: %v", raw.RuleProvider["geosite-cn"])
	}
}

func TestPrepareGeositeKeepsGeositeWhenTheSetsPredateTheGeoSiteFile(t *testing.T) {
	home := useHome(t)
	useGeositeMode(t, geositeRewrite)
	if err := os.WriteFile(filepath.Join(home, "GeoSite.dat"), []byte("v2"), 0o600); err != nil {
		t.Fatalf("write GeoSite.dat: %v", err)
	}
	dir := filepath.Join(home, geositeDirName)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	manifest := `{"source":"from-an-older-file","sets":{"cn":{"domain":true}}}`
	if err := os.WriteFile(filepath.Join(dir, "manifest.json"), []byte(manifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	raw := rawWithDNS([]string{"GEOSITE,cn,DIRECT"}, nil, nil)

	prepareGeosite(raw)

	if !reflect.DeepEqual(raw.Rule, []string{"GEOSITE,cn,DIRECT"}) {
		t.Errorf("rules = %v, want GEOSITE kept against a stale manifest", raw.Rule)
	}
}

func TestLoadConfigReadsTheCompiledSetsInThePacketTunnel(t *testing.T) {
	home := useHome(t)
	useGeositeMode(t, geositeRewrite)
	if err := os.WriteFile(filepath.Join(home, "GeoSite.dat"), []byte("compiled from this"), 0o600); err != nil {
		t.Fatalf("write GeoSite.dat: %v", err)
	}
	dir := filepath.Join(home, geositeDirName)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if _, err := writeGeositeSet(dir, "cn", []*router.Domain{{Type: router.Domain_Domain, Value: "example.cn"}}); err != nil {
		t.Fatalf("writeGeositeSet = %v", err)
	}
	manifest := `{"source":"` + geositeSource() + `","sets":{"cn":{"domain":true}}}`
	if err := os.WriteFile(filepath.Join(dir, "manifest.json"), []byte(manifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	profile := "rules:\n  - GEOSITE,cn,DIRECT\n  - MATCH,REJECT\n"
	if err := os.WriteFile(filepath.Join(home, "config.yaml"), []byte(profile), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	cfg, err := loadSetupConfig(&SetupParams{})

	if err != nil {
		t.Fatalf("loadSetupConfig = %v", err)
	}
	if got, want := ruleStrings(cfg), []string{"RuleSet,geosite-cn,DIRECT", "Match,,REJECT"}; !reflect.DeepEqual(got, want) {
		t.Errorf("rules = %v, want %v", got, want)
	}
	if _, ok := cfg.RuleProviders["geosite-cn"]; !ok {
		t.Error("the geosite-cn rule-set was not loaded")
	}
}
