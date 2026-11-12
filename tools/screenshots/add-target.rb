# يضيف هدف اختبار الصور (QBShotsUITests) ومخطط QBShots لنسخة project.yml على جهاز البناء بس.
# ما ينرفع للمستودع، وما يغيّر هدف التطبيق نفسه.
require 'yaml'

spec = YAML.load_file('project.yml')
spec['targets']['QBShotsUITests'] = {
  'type' => 'bundle.ui-testing',
  'platform' => 'iOS',
  'sources' => [{ 'path' => 'tools/screenshots/UITests' }],
  'dependencies' => [{ 'target' => 'QB' }],
  'settings' => {
    'base' => {
      'PRODUCT_BUNDLE_IDENTIFIER' => 'com.y.qb.shots',
      'TEST_TARGET_NAME' => 'QB',
      'GENERATE_INFOPLIST_FILE' => 'YES',
      'SWIFT_DEFAULT_ACTOR_ISOLATION' => 'nonisolated',
      'SWIFT_APPROACHABLE_CONCURRENCY' => 'NO',
      'SWIFT_STRICT_CONCURRENCY' => 'minimal'
    }
  }
}
spec['schemes']['QBShots'] = {
  'build' => { 'targets' => { 'QB' => 'all', 'QBWidget' => 'all', 'QBShotsUITests' => ['test'] } },
  'test' => { 'config' => 'Debug', 'targets' => ['QBShotsUITests'] }
}
File.write('project.yml', spec.to_yaml)
puts 'QBShotsUITests added'
