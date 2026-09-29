# Formatting for Format Document and the Format on Save commands: Ruby with
# RuboCop (the corrections it makes safely, as with `rubocop --autocorrect`),
# through ruby-lsp, the language server, which formats with RuboCop in
# projects whose bundle has it, or else by running RuboCop; and HTML views
# (.html.erb) with htmlbeautifier, which indents them.

# Tool tips are printed to stderr, as the standard output of commands can
# replace the document.
ruby_exit_tool_tip () { printf '%s' "$1" >&2; exit 206; }

# Whether a setting is on: 1, true, yes, or on.
ruby_enabled () {
	case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
		1|true|yes|on) return 0 ;;
		*)             return 1 ;;
	esac
}

# A folder for temporary files, removed when the command exits.
ruby_temporary_folder () {
	RUBY_TMP=$(mktemp -d "${TMPDIR:-/tmp}/textmate-ruby.XXXXXX") || exit 1
	trap "rm -rf $(printf '%q' "$RUBY_TMP")" EXIT
}

# Format the document with its language server, with the Language Server
# bundle (which the commands require, for TM_LANGUAGE_SERVER_BUNDLE_SUPPORT):
# its edits are applied in place, so they can be undone. Returns 0 when the
# document changed, 1 when there was nothing to change (or it has a syntax
# error), and 2 when it has no language server, or one that does not format
# (ruby-lsp, in projects whose bundle does not have RuboCop) or is starting.
# Shows why in a tool tip when formatting failed.
ruby_format_with_language_server () {
	local reason status
	[[ -x "${TM_LANGUAGE_SERVER_BUNDLE_SUPPORT:-}/bin/format" ]] || return 2
	reason=$("$TM_LANGUAGE_SERVER_BUNDLE_SUPPORT/bin/format" 2>&1 >/dev/null)
	status=$?
	(( status <= 2 )) || ruby_exit_tool_tip "$reason"
	return $status
}

# The folder of the closest Gemfile (or gems.rb) of the document, if any.
ruby_bundle_root () {
	local dir=${TM_DIRECTORY:-}
	while [[ -n "$dir" ]]; do
		if [[ -f "$dir/Gemfile" || -f "$dir/gems.rb" ]]; then
			echo "$dir"
			return 0
		fi
		[[ "$dir" == / ]] && break
		dir=$(dirname "$dir")
	done
	return 1
}

# Run the executable of a gem (named as the gem, such as rubocop) in the
# folder of the document’s bundle (or of the document): the command in
# TM_«GEM» (such as TM_RUBOCOP), when set; else with Bundler when the bundle
# has the gem, or else as installed, both with the Ruby that mise sets for the
# folder (when mise is installed) or from the PATH. Returns 127 when it is not
# installed.
ruby_gem_executable () { # gem, arguments…
	local gem=$1 variable folder mise command=()
	shift
	variable=TM_$(printf '%s' "$gem" | tr '[:lower:]-' '[:upper:]_')
	folder=$(ruby_bundle_root) || folder=${TM_DIRECTORY:-${TMPDIR:-/tmp}}
	cd "$folder" || return 1

	if [[ -n "${!variable:-}" ]]; then
		eval "command=(${!variable})"
	else
		for mise in "${TM_MISE:-}" "$(command -v mise)" "$HOME/.local/bin/mise" /opt/homebrew/bin/mise /usr/local/bin/mise; do
			[[ -n "$mise" && -x "$mise" ]] && break
			mise=
		done
		[[ -n "$mise" ]] && command=("$mise" exec --)
		if grep -qsE "^    $gem \\(" Gemfile.lock gems.locked; then
			command+=(bundle exec "$gem")
		elif [[ -n "$mise" ]] && ! "$mise" which "$gem" >/dev/null 2>&1 && ! command -v "$gem" >/dev/null; then
			return 127 # mise runs a shim for a gem of another Ruby, and fails
		else
			command+=("$gem")
		fi
	fi
	"${command[@]}" "$@"
}

# Replace the document with the text of a file (the document, formatted):
# through TextMate, which replaces only the lines that change, so that the
# caret, bookmarks, and folds elsewhere stay where they are; or else (such as
# for an untitled document) as the output of the command, keeping the caret
# on its line.
ruby_replace_document () { # file
	local params result
	if [[ -n "${TM_FILEPATH:-}" && -x "${TM_MATE:-}" ]]; then
		params=$(osascript -l JavaScript -e '
			ObjC.import("Foundation");
			function run(argv) {
				const text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js;
				const uri = $.NSURL.fileURLWithPath(argv[1]).absoluteString.js;
				const all = { start: { line: 0, character: 0 }, end: { line: 2147483647, character: 0 } }; // Past the last line
				return JSON.stringify({ label: "Format Document", edit: { changes: { [uri]: [{ range: all, newText: text }] } } });
			}' "$1" "$TM_FILEPATH" 2>/dev/null) &&
			result=$("$TM_MATE" --lsp workspace/applyEdit --lsp-params "$params" 2>/dev/null) &&
			[[ "$result" == *'"applied":true'* ]] && exit 200
	fi
	cat "$1"
	exit 202
}

# Format the document (the file) by running RuboCop, replacing it, or exit 200
# when there is nothing to change; or show why it could not be formatted. The
# options in TM_RUBOCOP_OPTIONS are added.
ruby_rubocop_format () { # input file
	local input=$1 path=${TM_FILEPATH:-${TM_DIRECTORY:-${TMPDIR:-/tmp}}/untitled.rb} options=() editor=(--editor-mode) status reason
	eval "options=(${TM_RUBOCOP_OPTIONS:-})"

	# --editor-mode (RuboCop 1.61 and later) leaves what is being written, such
	# as a variable not used yet, as ruby-lsp does.
	while true; do
		ruby_gem_executable rubocop --autocorrect "${editor[@]}" --stdin "$path" --stderr --format emacs --force-exclusion "${options[@]}" < "$input" > "$input.formatted" 2> "$input.errors"
		status=$?
		if (( status == 2 && ${#editor[@]} )) && grep -q -- '--editor-mode' "$input.errors"; then
			editor=()
			continue
		fi
		break
	done

	(( status == 127 )) && ruby_exit_tool_tip "RuboCop was not found. Install it with “gem install rubocop”, or add it to the project’s Gemfile."
	if (( status > 1 )); then
		reason=$(grep -v -e '^[[:space:]]*$' -e '^=*$' "$input.errors" | head -n 1)
		ruby_exit_tool_tip "Not formatted: ${reason:-RuboCop failed.}"
	fi

	reason=$(sed -nE 's/^.*:([0-9]+):[0-9]+: [EF]: Lint\/Syntax: (.*)$/line \1: \2/p' "$input.errors" | head -n 1)
	[[ -z "$reason" ]] || ruby_exit_tool_tip "Not formatted, as there is a syntax error on ${reason% (Using Ruby *}"
	[[ -s "$input.formatted" || ! -s "$input" ]] || ruby_exit_tool_tip "Not formatted: RuboCop printed nothing."

	cmp -s "$input" "$input.formatted" && exit 200
	ruby_replace_document "$input.formatted"
}

# Format the document (standard input) with RuboCop: through ruby-lsp, or
# else by running RuboCop.
ruby_format_document () {
	ruby_temporary_folder
	cat > "$RUBY_TMP/input"

	ruby_format_with_language_server
	(( $? == 2 )) || exit 200
	ruby_rubocop_format "$RUBY_TMP/input"
}

# Indent the document (standard input), an HTML view (.html.erb), with
# htmlbeautifier, with the document’s tab settings, keeping a blank line
# between blocks (rather than none); the options in TM_HTMLBEAUTIFIER_OPTIONS
# are added. Exits 200 when there is nothing to change, or htmlbeautifier is
# not installed, and shows why when it can’t be indented, such as for a
# closing tag without an opening one.
ruby_erb_format () {
	local indent=(--tab-stops "${TM_TAB_SIZE:-2}") options=() status reason
	case "${TM_FILEPATH:-}" in
		*.html.erb|*.html+*.erb) ;; # Such as show.html+phone.erb
		*) exit 200 ;;              # Not an HTML view, such as a mailer’s text
	esac
	[[ "${TM_SOFT_TABS:-YES}" == NO ]] && indent=(--tab)
	eval "options=(${TM_HTMLBEAUTIFIER_OPTIONS:-})"

	ruby_temporary_folder
	cat > "$RUBY_TMP/input"
	ruby_gem_executable htmlbeautifier "${indent[@]}" --keep-blank-lines 1 --stop-on-errors "${options[@]}" < "$RUBY_TMP/input" > "$RUBY_TMP/formatted" 2> "$RUBY_TMP/errors"
	status=$?

	(( status == 127 )) && exit 200
	if (( status != 0 )); then
		reason=$(sed -nE 's/^.*Error parsing standard input: (.*) \(RuntimeError\)$/\1/p' "$RUBY_TMP/errors" | head -n 1)
		[[ -n "$reason" ]] || reason=$(grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*from ' "$RUBY_TMP/errors" | head -n 1)
		ruby_exit_tool_tip "Not indented: ${reason:-htmlbeautifier failed.}"
	fi

	[[ -s "$RUBY_TMP/formatted" ]] || exit 200
	cmp -s "$RUBY_TMP/input" "$RUBY_TMP/formatted" && exit 200
	ruby_replace_document "$RUBY_TMP/formatted"
}
