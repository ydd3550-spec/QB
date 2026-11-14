# يضيف هدف فحص المشغّل (QBCheckUITests) ومخطط QBCheck لنسخة project.yml على جهاز البناء بس.
require 'yaml'

spec = YAML.load_file('project.yml')
spec['targets']['QBCheckUITests'] = {
  'type' => 'bundle.ui-testing',
  'platform' => 'iOS',
  'sources' => [{ 'path' => 'tools/b9check/UITests' }],
  'dependencies' => [{ 'target' => 'QB' }],
  'settings' => {
    'base' => {
      'PRODUCT_BUNDLE_IDENTIFIER' => 'com.y.qb.check',
      'TEST_TARGET_NAME' => 'QB',
      'GENERATE_INFOPLIST_FILE' => 'YES',
      'SWIFT_DEFAULT_ACTOR_ISOLATION' => 'nonisolated',
      'SWIFT_APPROACHABLE_CONCURRENCY' => 'NO',
      'SWIFT_STRICT_CONCURRENCY' => 'minimal'
    }
  }
}
spec['schemes']['QBCheck'] = {
  'build' => { 'targets' => { 'QB' => 'all', 'QBWidget' => 'all', 'QBCheckUITests' => ['test'] } },
  'test' => { 'config' => 'Debug', 'targets' => ['QBCheckUITests'] }
}
File.write('project.yml', spec.to_yaml)
puts 'QBCheckUITests added'
