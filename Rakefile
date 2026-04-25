require 'bundler/gem_tasks'
require 'rake/testtask'

Rake::TestTask.new(:unit) do |t|
  t.test_files = ['test/unit_test.rb']
  t.warning = false
end

Rake::TestTask.new(:integration) do |t|
  t.test_files = ['test/integration_test.rb']
  t.warning = false
end

Rake::TestTask.new(:test) do |t|
  t.test_files = FileList['test/*_test.rb']
  t.warning = false
end

task default: :test
