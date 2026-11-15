# Usage: ruby gen_configs.rb <base config.yaml> <output dir>
# Copies reuse the base servers in a plain select group, so no extra node is ever dialed or health-checked.
require 'yaml'
require 'set'

base_path, out_dir = ARGV
base = YAML.load_file(base_path)

def scaled(base, nodes, rules)
  config = Marshal.load(Marshal.dump(base))
  return config if nodes.zero?

  originals = config['proxies']
  copies = (0...nodes).map do |i|
    originals[i % originals.size].merge('name' => format('bulk-%05d', i))
  end
  config['proxies'] = originals + copies
  config['proxy-groups'] << { 'name' => 'bulk', 'type' => 'select', 'proxies' => copies.map { |p| p['name'] } }
  generated = (0...rules).map do |i|
    case i % 3
    when 0 then format('DOMAIN-SUFFIX,host%06d.example-%d.com,bulk', i, i % 97)
    when 1 then format('DOMAIN-KEYWORD,kw%06d,DIRECT', i)
    else format('IP-CIDR,10.%d.%d.0/24,DIRECT,no-resolve', (i / 256) % 256, i % 256)
    end
  end
  config['rules'] = generated + config['rules']
  config
end

def geo_key(key, codes)
  return key unless key.start_with?('geosite:')

  list = key.delete_prefix('geosite:').split(',').map(&:downcase)
  codes.merge(list)
  'rule-set:' + list.map { |code| "geosite-#{code}" }.join(',')
end

def with_mrs(config, codes)
  config = Marshal.load(Marshal.dump(config))
  config['rules'] = config['rules'].map do |rule|
    rule.sub(/\AGEOSITE,([^,]+)/) do
      codes << Regexp.last_match(1).downcase
      "RULE-SET,geosite-#{Regexp.last_match(1).downcase}"
    end
  end
  dns = config['dns'] || {}
  dns['nameserver-policy'] = dns['nameserver-policy'].to_h { |k, v| [geo_key(k, codes), v] } if dns['nameserver-policy']
  dns['fake-ip-filter'] = dns['fake-ip-filter'].map { |entry| geo_key(entry, codes) } if dns['fake-ip-filter']
  providers = codes.to_h do |code|
    ["geosite-#{code}", { 'type' => 'file', 'behavior' => 'domain', 'format' => 'mrs', 'path' => "./geosite-#{code}.mrs" }]
  end
  config['rule-providers'] = (config['rule-providers'] || {}).merge(providers)
  config
end

codes = Set.new
{ 'small' => [0, 0], 'large' => [1000, 30_000], 'xlarge' => [3000, 100_000] }.each do |name, (nodes, rules)|
  config = scaled(base, nodes, rules)
  File.write(File.join(out_dir, "config-#{name}.yaml"), config.to_yaml)
  File.write(File.join(out_dir, "config-#{name}-mrs.yaml"), with_mrs(config, codes).to_yaml)
end
File.write(File.join(out_dir, 'geosite-codes.txt'), codes.to_a.join("\n") + "\n")
