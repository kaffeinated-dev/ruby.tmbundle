require 'minitest/autorun'
require 'cgi'
require 'fileutils'
require 'open3'
require 'tmpdir'

Encoding.default_external = Encoding::UTF_8

# Runs Format Document and the Format on Save commands (bash) as TextMate
# does, with a fake Language Server bundle (its bin/format exits as the test
# says), and a fake mise, Bundler, RuboCop, htmlbeautifier, and mate that log
# their arguments.
class TestFormat < Minitest::Test
  BUNDLE = File.expand_path('../..', __dir__)

  MESSY = "def  hi( x )\n  puts \"hi \#{x}\"\nend\n"
  FORMATTED = "def hi(x)\n  puts \"hi \#{x}\"\nend\n"
  VIEW = "<ul>\n<% @posts.each do |post| %>\n<li><%= post.title %></li>\n<% end %>\n</ul>\n"
  INDENTED = "<ul>\n  <% @posts.each do |post| %>\n    <li><%= post.title %></li>\n  <% end %>\n</ul>\n"

  def self.command(name)
    plist = File.read(File.join(BUNDLE, 'Commands', "#{name}.tmCommand"), encoding: 'UTF-8')
    CGI.unescapeHTML(plist[%r{<key>command</key>\s*<string>(.*?)</string>}m, 1])
  end

  def setup
    @dir = File.realpath(Dir.mktmpdir)
    @project = File.join(@dir, 'project')
    @bin = File.join(@dir, 'bin')
    @tmp = File.join(@dir, 'tmp')
    FileUtils.mkdir_p([File.join(@project, 'lib'), File.join(@project, 'app/views/posts'), @bin, @tmp])
    File.write(File.join(@project, 'Gemfile'), "source 'https://rubygems.org'\n")
    File.write(File.join(@project, 'lib/hi.rb'), MESSY)
    File.write(File.join(@project, 'app/views/posts/index.html.erb'), VIEW)

    @language_server = File.join(@dir, 'Language Server/Support')
    FileUtils.mkdir_p(File.join(@language_server, 'bin'))
    format_with_language_server(status: 2, errors: 'The language server of this document does not format documents.')

    fake('mise', <<~BASH)
      [[ "$1 $2" == "exec --" ]] && shift 2
      exec "$@"
    BASH
    rubocop(output: FORMATTED)
    htmlbeautifier(output: INDENTED)
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

  # A fake htmlbeautifier, as the fake RuboCop.
  def htmlbeautifier(output:, errors: '', status: 0)
    fake('htmlbeautifier', <<~BASH)
      cat > /dev/null
      #{output.empty? ? '' : "cat <<'HTML'\n#{output}HTML"}
      #{errors.empty? ? '' : "cat >&2 <<'ERRORS'\n#{errors}ERRORS"}
      exit #{status}
    BASH
  end

  # A fake mate, whose answer to mate --lsp workspace/applyEdit is RESULT.
  def mate(result: '{"result":{"applied":true}}')
    fake('mate', "printf '%s' '#{result}'")
    File.join(@bin, 'mate')
  end

  # The params of the edit applied with the fake mate.
  def applied_edit
    require 'json'
    JSON.parse(log[/^mate \(\w+\): --lsp workspace\/applyEdit --lsp-params (.*)$/, 1])
  end

  def fake(name, script)
    path = File.join(@bin, name)
    File.write(path, "#!/bin/bash\nprintf '%s\\n' \"#{name} ($(basename \"$PWD\")): $*\" >> '#{@dir}/log'\n#{script}\n")
    File.chmod(0o755, path)
  end

  def log
    File.exist?(File.join(@dir, 'log')) ? File.read(File.join(@dir, 'log')) : ''
  end

  # Runs the command as TextMate does: its script as a file.
  def run_command(name, file: 'lib/hi.rb', env: {})
    path = File.expand_path(file, @project)
    script = File.join(@dir, 'command')
    File.write(script, self.class.command(name))
    File.chmod(0o755, script)
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
    output, errors, status = Open3.capture3(environment, script, stdin_data: File.read(path), unsetenv_others: true)
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
    assert_equal "format\nmise (project): which rubocop\nmise (project): exec -- rubocop --autocorrect --editor-mode --stdin #{@project}/lib/hi.rb --stderr --format emacs --force-exclusion --only Layout\nrubocop (project): --autocorrect --editor-mode --stdin #{@project}/lib/hi.rb --stderr --format emacs --force-exclusion --only Layout\n", log

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

  def test_rubocop_changes_are_applied_by_textmate
    skip 'needs osascript' unless File.executable?('/usr/bin/osascript')
    assert_equal({ status: 200, output: '', errors: '' }, run_command('Format Document', env: { 'TM_MATE' => mate }))
    edit = applied_edit['edit']['changes']["file://#{@project}/lib/hi.rb"]
    assert_equal [{ 'range' => { 'start' => { 'line' => 0, 'character' => 0 }, 'end' => { 'line' => 2147483647, 'character' => 0 } }, 'newText' => FORMATTED }], edit

    # Replacing the document, when TextMate can't.
    assert_equal({ status: 202, output: FORMATTED, errors: '' }, run_command('Format Document', env: { 'TM_MATE' => mate(result: '{"result":{"applied":false}}') }))
  end

  def test_views_are_indented_on_save
    result = run_command('Format ERB on Save', file: 'app/views/posts/index.html.erb', env: { 'TM_TAB_SIZE' => '2', 'TM_SOFT_TABS' => 'YES', 'TM_HTMLBEAUTIFIER_OPTIONS' => '--keep-blank-lines 2' })
    assert_equal({ status: 202, output: INDENTED, errors: '' }, result)
    assert_includes log, 'htmlbeautifier (project): --tab-stops 2 --keep-blank-lines 1 --stop-on-errors --keep-blank-lines 2'

    run_command('Format ERB on Save', file: 'app/views/posts/index.html.erb', env: { 'TM_SOFT_TABS' => 'NO' })
    assert_includes log, 'htmlbeautifier (project): --tab --keep-blank-lines 1 --stop-on-errors'
  end

  def test_view_changes_are_applied_by_textmate
    skip 'needs osascript' unless File.executable?('/usr/bin/osascript')
    result = run_command('Format ERB on Save', file: 'app/views/posts/index.html.erb', env: { 'TM_MATE' => mate })
    assert_equal({ status: 200, output: '', errors: '' }, result)
    assert_equal INDENTED, applied_edit['edit']['changes']["file://#{@project}/app/views/posts/index.html.erb"][0]['newText']
  end

  def test_only_html_views_are_indented
    FileUtils.mkdir_p(File.join(@project, 'app/views/mailer'))
    File.write(File.join(@project, 'app/views/mailer/welcome.text.erb'), VIEW)
    assert_equal({ status: 200, output: '', errors: '' }, run_command('Format ERB on Save', file: 'app/views/mailer/welcome.text.erb'))

    File.write(File.join(@project, 'app/views/posts/index.html+phone.erb'), VIEW)
    assert_equal 202, run_command('Format ERB on Save', file: 'app/views/posts/index.html+phone.erb')[:status]
  end

  def test_views_are_left_when_turned_off_or_formatted
    assert_equal 200, run_command('Format ERB on Save', file: 'app/views/posts/index.html.erb', env: { 'TM_ERB_FORMAT_ON_SAVE' => 'false' })[:status]
    refute_includes log, 'htmlbeautifier'

    htmlbeautifier(output: VIEW)
    assert_equal({ status: 200, output: '', errors: '' }, run_command('Format ERB on Save', file: 'app/views/posts/index.html.erb'))
  end

  def test_views_are_left_without_htmlbeautifier
    result = run_command('Format ERB on Save', file: 'app/views/posts/index.html.erb', env: { 'TM_MISE' => nil, 'PATH' => '/usr/bin:/bin' })
    assert_equal({ status: 200, output: '', errors: '' }, result)

    # With mise, for a Ruby without it.
    fake('mise', '[[ "$1" == which ]] && exit 1; [[ "$1 $2" == "exec --" ]] && shift 2; exec "$@"')
    result = run_command('Format ERB on Save', file: 'app/views/posts/index.html.erb', env: { 'PATH' => '/usr/bin:/bin' })
    assert_equal({ status: 200, output: '', errors: '' }, result)
  end

  def test_htmlbeautifier_of_the_bundle_is_used
    File.write(File.join(@project, 'Gemfile.lock'), "GEM\n  specs:\n    htmlbeautifier (1.4.3)\n")
    assert_equal 202, run_command('Format ERB on Save', file: 'app/views/posts/index.html.erb')[:status]
    assert_includes log, 'bundle (project): exec htmlbeautifier --tab-stops'
  end

  def test_views_with_invalid_nesting_are_left
    htmlbeautifier(output: '', status: 1, errors: "/gems/htmlbeautifier-1.4.3/bin/htmlbeautifier:12:in 'Object#beautify': Error parsing standard input: Extraneous closing tag on line 3 (RuntimeError)\n\tfrom /gems/htmlbeautifier-1.4.3/bin/htmlbeautifier:111:in '<top (required)>'\n")
    result = run_command('Format ERB on Save', file: 'app/views/posts/index.html.erb')
    assert_equal({ status: 206, output: '', errors: 'Not indented: Extraneous closing tag on line 3' }, result)
  end
end
