package core

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"github.com/metacubex/mihomo/common/orderedmap"
	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/geodata/router"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/log"
	rp "github.com/metacubex/mihomo/rules/provider"
)

// A GeoSite list decodes whole and stays cached for the Core's lifetime:
// GEOSITE,cn alone keeps over 10 MB, a fifth of what iOS lets a packet tunnel
// use. On iOS the app's Core compiles each list a config names into an mrs
// domain set, and the packet tunnel's Core reads those sets instead.
type geositeHandling int

const (
	geositeKeep geositeHandling = iota
	geositeCompile
	geositeRewrite
)

var geositeMode = defaultGeositeMode

const geositeDirName = "geosite"

var geositeReference = regexp.MustCompile(`(?i)\bGEOSITE,([^,()\s]+)`)

// An mrs domain set holds exact and suffix domains only; a list's keyword and
// regex entries go to a small classical set beside it.
type geositeSet struct {
	Domain bool `json:"domain"`
	Extra  bool `json:"extra"`
}

type geositeManifest struct {
	Source string                `json:"source"`
	Sets   map[string]geositeSet `json:"sets"`
}

func prepareGeosite(raw *config.RawConfig) {
	switch geositeMode {
	case geositeCompile:
		if err := compileGeositeSets(geositeDir(), geositeCodes(raw)); err != nil {
			log.Warnln("[GeoSite] compiling rule-sets failed: %v", err)
		}
	case geositeRewrite:
		manifest := readGeositeManifest(geositeDir())
		if manifest.Source != "" && manifest.Source == geositeSource() {
			rewriteGeosite(raw, manifest.Sets)
		}
	}
}

func geositeDir() string {
	return filepath.Join(constant.Path.HomeDir(), geositeDirName)
}

func geositeSource() string {
	info, err := os.Stat(constant.Path.GeoSite())
	if err != nil {
		return ""
	}
	return fmt.Sprintf("%d-%d", info.Size(), info.ModTime().UnixNano())
}

// A code with an attribute or a negation stays a GEOSITE reference.
func convertibleGeositeCode(code string) (string, bool) {
	code = strings.ToLower(strings.TrimSpace(code))
	return code, code != "" && !strings.ContainsAny(code, "@!")
}

func geositeCodes(raw *config.RawConfig) []string {
	var codes []string
	add := func(code string) {
		if code, ok := convertibleGeositeCode(code); ok && !slices.Contains(codes, code) {
			codes = append(codes, code)
		}
	}
	addRules := func(rules []string) {
		for _, rule := range rules {
			for _, match := range geositeReference.FindAllStringSubmatch(rule, -1) {
				add(match[1])
			}
		}
	}
	addRules(raw.Rule)
	for _, rules := range raw.SubRules {
		addRules(rules)
	}
	for _, key := range dnsGeositeKeys(raw) {
		for _, code := range strings.Split(key[len("geosite:"):], ",") {
			add(code)
		}
	}
	slices.Sort(codes)
	return codes
}

func dnsGeositeKeys(raw *config.RawConfig) []string {
	var keys []string
	if policy := raw.DNS.NameServerPolicy; policy != nil {
		for pair := policy.Oldest(); pair != nil; pair = pair.Next() {
			if hasGeositePrefix(pair.Key) {
				keys = append(keys, pair.Key)
			}
		}
	}
	for _, entry := range raw.DNS.FakeIPFilter {
		if hasGeositePrefix(entry) {
			keys = append(keys, entry)
		}
	}
	return keys
}

func hasGeositePrefix(value string) bool {
	return len(value) > len("geosite:") && strings.EqualFold(value[:len("geosite:")], "geosite:")
}

func readGeositeManifest(dir string) geositeManifest {
	manifest := geositeManifest{Sets: map[string]geositeSet{}}
	if buf, err := os.ReadFile(filepath.Join(dir, "manifest.json")); err == nil {
		_ = json.Unmarshal(buf, &manifest)
	}
	if manifest.Sets == nil {
		manifest.Sets = map[string]geositeSet{}
	}
	return manifest
}

func compileGeositeSets(dir string, codes []string) error {
	if len(codes) == 0 {
		return nil
	}
	source := geositeSource()
	if source == "" {
		return nil
	}
	manifest := readGeositeManifest(dir)
	changed := manifest.Source != source
	if changed {
		manifest = geositeManifest{Source: source, Sets: map[string]geositeSet{}}
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	loader, err := geodata.GetGeoDataLoader(geodata.LoaderName())
	if err != nil {
		return err
	}
	for _, code := range codes {
		if _, done := manifest.Sets[code]; done {
			continue
		}
		domains, err := loader.LoadGeoSite(code)
		if err != nil {
			log.Warnln("[GeoSite] %s stays a GEOSITE rule: %v", code, err)
			continue
		}
		set, err := writeGeositeSet(dir, code, domains)
		if err != nil {
			return err
		}
		manifest.Sets[code] = set
		changed = true
	}
	if !changed {
		return nil
	}
	buf, err := json.Marshal(manifest)
	if err != nil {
		return err
	}
	return writeFileAtomically(filepath.Join(dir, "manifest.json"), buf)
}

func writeGeositeSet(dir, code string, domains []*router.Domain) (geositeSet, error) {
	var plain, extra bytes.Buffer
	for _, domain := range domains {
		switch domain.Type {
		case router.Domain_Full:
			fmt.Fprintln(&plain, domain.Value)
		case router.Domain_Domain:
			fmt.Fprintln(&plain, "+."+domain.Value)
		case router.Domain_Plain:
			fmt.Fprintln(&extra, "DOMAIN-KEYWORD,"+domain.Value)
		case router.Domain_Regex:
			fmt.Fprintln(&extra, "DOMAIN-REGEX,"+domain.Value)
		}
	}
	var set geositeSet
	if plain.Len() > 0 {
		var mrs bytes.Buffer
		if err := rp.ConvertToMrs(plain.Bytes(), cp.Domain, cp.TextRule, &mrs); err != nil {
			return set, err
		}
		if err := writeFileAtomically(filepath.Join(dir, code+".mrs"), mrs.Bytes()); err != nil {
			return set, err
		}
		set.Domain = true
	}
	if extra.Len() > 0 {
		if err := writeFileAtomically(filepath.Join(dir, code+"-extra.list"), extra.Bytes()); err != nil {
			return set, err
		}
		set.Extra = true
	}
	return set, nil
}

func writeFileAtomically(path string, buf []byte) error {
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, buf, 0o644); err != nil {
		return err
	}
	if err := os.Rename(temporary, path); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	return nil
}

// rewriteGeosite points every reference to a compiled list at its rule-sets.
// A reference nested in a logic rule is replaced only when one set covers the
// list, since a second set would need an OR the rule does not have.
func rewriteGeosite(raw *config.RawConfig, sets map[string]geositeSet) {
	used := map[string]geositeSet{}
	names := func(code string) []string {
		code, ok := convertibleGeositeCode(code)
		set, compiled := sets[code]
		if !ok || !compiled {
			return nil
		}
		var names []string
		if set.Domain {
			names = append(names, "geosite-"+code)
		}
		if set.Extra {
			names = append(names, "geosite-"+code+"-extra")
		}
		for _, name := range names {
			if _, taken := raw.RuleProvider[name]; taken {
				return nil
			}
		}
		used[code] = set
		return names
	}
	rewriteRules := func(rules []string) []string {
		rewritten := make([]string, 0, len(rules))
		for _, rule := range rules {
			rewritten = append(rewritten, rewriteGeositeRule(rule, names)...)
		}
		return rewritten
	}
	raw.Rule = rewriteRules(raw.Rule)
	for name, rules := range raw.SubRules {
		raw.SubRules[name] = rewriteRules(rules)
	}
	if policy := raw.DNS.NameServerPolicy; policy != nil {
		rewritten := orderedmap.New[string, any]()
		for pair := policy.Oldest(); pair != nil; pair = pair.Next() {
			rewritten.Set(rewriteGeositeKey(pair.Key, names), pair.Value)
		}
		raw.DNS.NameServerPolicy = rewritten
	}
	filter := make([]string, 0, len(raw.DNS.FakeIPFilter))
	for _, entry := range raw.DNS.FakeIPFilter {
		key := rewriteGeositeKey(entry, names)
		if key == entry {
			filter = append(filter, entry)
			continue
		}
		for _, name := range strings.Split(key[len("rule-set:"):], ",") {
			filter = append(filter, "rule-set:"+name)
		}
	}
	raw.DNS.FakeIPFilter = filter
	addGeositeProviders(raw, used)
}

func rewriteGeositeRule(rule string, names func(string) []string) []string {
	kind, rest, _ := strings.Cut(rule, ",")
	if strings.EqualFold(strings.TrimSpace(kind), "GEOSITE") {
		code, target, _ := strings.Cut(rest, ",")
		sets := names(code)
		if len(sets) == 0 {
			return []string{rule}
		}
		rules := make([]string, 0, len(sets))
		for _, name := range sets {
			rules = append(rules, "RULE-SET,"+name+","+target)
		}
		return rules
	}
	return []string{geositeReference.ReplaceAllStringFunc(rule, func(match string) string {
		sets := names(geositeReference.FindStringSubmatch(match)[1])
		if len(sets) != 1 {
			return match
		}
		return "RULE-SET," + sets[0]
	})}
}

// A key keeps its GEOSITE form unless every list it names is compiled.
func rewriteGeositeKey(key string, names func(string) []string) string {
	if !hasGeositePrefix(key) {
		return key
	}
	var sets []string
	for _, code := range strings.Split(key[len("geosite:"):], ",") {
		found := names(code)
		if len(found) == 0 {
			return key
		}
		sets = append(sets, found...)
	}
	return "rule-set:" + strings.Join(sets, ",")
}

func addGeositeProviders(raw *config.RawConfig, used map[string]geositeSet) {
	if len(used) == 0 {
		return
	}
	if raw.RuleProvider == nil {
		raw.RuleProvider = map[string]map[string]any{}
	}
	add := func(name, behavior, format, file string) {
		raw.RuleProvider[name] = map[string]any{
			"type":     "file",
			"behavior": behavior,
			"format":   format,
			"path":     "./" + geositeDirName + "/" + file,
		}
	}
	for code, set := range used {
		if set.Domain {
			add("geosite-"+code, "domain", "mrs", code+".mrs")
		}
		if set.Extra {
			add("geosite-"+code+"-extra", "classical", "text", code+"-extra.list")
		}
	}
}
