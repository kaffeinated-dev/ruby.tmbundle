require 'minitest/autorun'
require 'cgi'
require 'fileutils'
require 'open3'
require 'tmpdir'

Encoding.default_external = Encoding::UTF_8

# Runs Format Document and Format on Save (bash) as TextMate does, with a
# fake Language Server bundle (its bin/format exits as the test says), and a
# fake mise, Bundler, and RuboCop that log their arguments.
class TestRuboCop < Minitest::Test
  BUNDLE = File.expand_path('../..', __dir__)

  MESSY = "def  hi( x )\n  puts \"hi \#{x}\"\nend\n"
  FORMATTED = "def hi(x)\n  puts \"hi \#{x}\"\nend\n"

  def self.command(name)
    plist = File.read(File.join(BUNDLE, 'Commands', "#{name}.tmCommand"), encoding: 'UTF-8')
    CGI.unescapeHTML(plist[%r{<key>command</key>\s*<string>(.*?)</string>}m, 1])
  end

  def setup
    @dir = File.realpath(Dir.mktmpdir)
    @project = File.join(@dir, 'project')
    @bin = File.join(@dir, 'bin')
    @tmp = File.join(@dir, 'tmp')
    FileUtils.mkdir_p([File.join(@project, 'lib'), @bin, @tmp])
    File.write(File.join(@project, 'Gemfile'), "source 'https://rubygems.org'\n")
    File.write(File.join(@project, 'lib/hi.rb'), MESSY)

    @language_server = File.join(@dir, 'Language Server/Support')
    FileUtils.mkdir_p(File.join(@language_server, 'bin'))
    format_with_language_server(status: 2, errors: 'The language server of this document does not format documents.')

    fake('mise', <<~BASH)
      [[ "$1 $2" == "exec --" ]] && shift 2
      exec "$@"
    BASH
    rubocop(output: FORMATTED)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # The fake bin/format of the Language Server bundle.
  def format_with_language_server(status:, errors: '')
    script = "echo format >> '#{@dir}/log'\nprintf '%s\\n' '#{errors}' >&2\nexit #{status}\n"
    File.write(File.join(@language_server, 'bin/format'), "#!/bin/bash\n#{script}")
    File.chmod(0o755, File.join(@language_server, 'bin/format'))
  end

  # A fake RuboCop: prints OUTPUT (the document, formatted) and ERRORS, and
  # exits with STATUS. Without editor mode, it fails for --editor-mode.
  def rubocop(output:, errors: '', status: 1, editor_mode: true)
    fake('rubocop', <<~BASH)
      cat > /dev/null
      #{editor_mode ? '' : %([[ " $* " == *" --editor-mode "* ]] && { echo 'invalid option: --editor-mode' >&2; exit 2; })}
      #{output.empty? ? '' : "cat <<'RUBY'\n#{output}RUBY"}
      printf '%s' '#{errors}' >&2
      exit #{status}
    BASH
    fake('bundle', '[[ "$1" == exec ]] && shift; exec "$@"')
  end

  def fake(name, script)
    path = File.join(@bin, name)
    File.write(path, "#!/bin/bash\nprintf '%s\\n' \"#{name} ($(basename \"$PWD\")): $*\" >> '#{@dir}/log'\n#{script}\n")
    File.chmod(0o755, path)
  end

  def log
    File.exist?(File.join(@dir, 'log')) ? File.read(File.join(@dir, 'log')) : ''
  end

  def run_command(name, file: 'lib/hi.rb', env: {})
    path = File.expand_path(file, @project)
    environment = {
      'PATH' => "#{@bin}:/usr/bin:/bin:/usr/sbin:/sbin",
      'HOME' => @dir,
      'TMPDIR' => @tmp,
      'TM_BUNDLE_SUPPORT' => File.join(BUNDLE, 'Support'),
      'TM_LANGUAGE_SERVER_BUNDLE_SUPPORT' => @language_server,
      'TM_MISE' => File.join(@bin, 'mise'),
      'TM_FILEPATH' => path,
      'TM_DIRECTORY' => File.dirname(path),
    }.merge(env).compact
    output, errors, status = Open3.capture3(environment, '/bin/bash', '-c', self.class.command(name), stdin_data: File.read(path), unsetenv_others: true)
    { status: status.exitstatus, output: output, errors: errors }
  end

  def test_documents_are_formatted_by_the_language_server
    format_with_language_server(status: 0)
    assert_equal({ status: 200, output: '', errors: '' }, run_command('Format Document'))
    assert_equal "format\n", log

    format_with_language_server(status: 1) # Nothing to change
    assert_equal 200, run_command('Format Document')[:status]
    refute_includes log, 'rubocop'
  end

  def test_errors_of_the_language_server_are_shown
    format_with_language_server(status: 206, errors: 'The language server did not respond in time.')
    assert_equal({ status: 206, output: '', errors: 'The language server did not respond in time.' }, run_command('Format Document'))
  end

  def test_rubocop_formats_without_a_language_server_that_formats
    assert_equal({ status: 202, output: FORMATTED, errors: '' }, run_command('Format Document', env: { 'TM_RUBOCOP_OPTIONS' => '--only Layout' }))
    assert_equal "format\nmise (project): exec -- rubocop --autocorrect --editor-mode --stdin #{@project}/lib/hi.rb --stderr --format emacs --force-exclusion --only Layout\nrubocop (project): --autocorrect --editor-mode --stdin #{@project}/lib/hi.rb --stderr --format emacs --force-exclusion --only Layout\n", log

    # Nor without the Language Server bundle.
    assert_equal 202, run_command('Format Document', env: { 'TM_LANGUAGE_SERVER_BUNDLE_SUPPORT' => nil })[:status]
  end

  def test_rubocop_of_the_bundle_is_used
    File.write(File.join(@project, 'Gemfile.lock'), "GEM\n  specs:\n    rubocop (1.87.0)\n")
    FileUtils.mkdir_p(File.join(@project, 'lib/deep'))
    File.write(File.join(@project, 'lib/deep/hi.rb'), MESSY)

    assert_equal 202, run_command('Format Document', file: 'lib/deep/hi.rb')[:status]
    assert_includes log, "mise (project): exec -- bundle exec rubocop --autocorrect"
    assert_includes log, "bundle (project): exec rubocop --autocorrect"
  end

  def test_scripts_outside_a_bundle_are_formatted
    FileUtils.mkdir_p(File.join(@dir, 'scripts'))
    File.write(File.join(@dir, 'scripts/hi.rb'), MESSY)
    result = run_command('Format Document', file: '../scripts/hi.rb', env: { 'TM_MISE' => nil, 'TM_RUBOCOP' => "#{@bin}/rubocop --config 'my config.yml'" })
    assert_equal FORMATTED, result[:output]
    assert_includes log, "rubocop (scripts): --config my config.yml --autocorrect"
  end

  def test_rubocop_without_editor_mode
    rubocop(output: FORMATTED, editor_mode: false)
    assert_equal({ status: 202, output: FORMATTED, errors: '' }, run_command('Format Document'))
    assert_match(/rubocop \(project\): --autocorrect --stdin/, log)
  end

  def test_nothing_happens_without_changes
    rubocop(output: MESSY)
    assert_equal({ status: 200, output: '', errors: '' }, run_command('Format Document'))
  end

  def test_rubocop_errors_are_shown
    rubocop(output: MESSY, errors: "#{@project}/lib/hi.rb:2:3: F: Lint/Syntax: unexpected integer; expected a `)` (Using Ruby 3.4 parser; configure using `TargetRubyVersion` parameter, under `AllCops`)\n")
    assert_equal 'Not formatted, as there is a syntax error on line 2: unexpected integer; expected a `)`', run_command('Format Document')[:errors]

    rubocop(output: '', errors: "\ninvalid option: --bogus\nFor usage information, use --help\n", status: 2)
    assert_equal({ status: 206, output: '', errors: 'Not formatted: invalid option: --bogus' }, run_command('Format Document'))

    rubocop(output: '', status: 1)
    assert_equal 'Not formatted: RuboCop printed nothing.', run_command('Format Document')[:errors]

    result = run_command('Format Document', env: { 'TM_MISE' => nil, 'PATH' => '/usr/bin:/bin' })
    assert_equal({ status: 206, output: '', errors: 'RuboCop was not found. Install it with “gem install rubocop”, or add it to the project’s Gemfile.' }, result)
  end

  def test_the_temporary_folder_is_removed
    run_command('Format Document')
    assert_empty Dir.children(@tmp)
  end

  def test_documents_are_formatted_on_save
    format_with_language_server(status: 0)
    assert_equal({ status: 200, output: '', errors: '' }, run_command('Format on Save'))
    assert_equal "format\n", log

    # Not by running RuboCop, nor when turned off.
    format_with_language_server(status: 2, errors: 'The language server of this document does not format documents.')
    assert_equal({ status: 200, output: '', errors: '' }, run_command('Format on Save'))
    assert_equal({ status: 200, output: '', errors: '' }, run_command('Format on Save', env: { 'TM_RUBY_FORMAT_ON_SAVE' => 'False' }))
    assert_equal "format\nformat\n", log

    format_with_language_server(status: 206, errors: 'The language server did not respond in time.')
    assert_equal 206, run_command('Format on Save')[:status]
  end
end
