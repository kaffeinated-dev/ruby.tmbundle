# Formatting Ruby with RuboCop (the corrections it makes safely, as with
# `rubocop --autocorrect`), for Format Document and Format on Save: through
# ruby-lsp, the language server, which formats with RuboCop in projects whose
# bundle has it, or else by running RuboCop.

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

# Run RuboCop in the folder of the document’s bundle (or of the document):
# TM_RUBOCOP, when set; else with Bundler when the bundle has RuboCop, or else
# rubocop, both with the Ruby that mise sets for the folder (when installed)
# or from the PATH.
ruby_rubocop () { # arguments…
	local folder mise command=()
	folder=$(ruby_bundle_root) || folder=${TM_DIRECTORY:-${TMPDIR:-/tmp}}
	cd "$folder" || return 1

	if [[ -n "${TM_RUBOCOP:-}" ]]; then
		eval "command=($TM_RUBOCOP)"
	else
		for mise in "${TM_MISE:-}" "$(command -v mise)" "$HOME/.local/bin/mise" /opt/homebrew/bin/mise /usr/local/bin/mise; do
			[[ -n "$mise" && -x "$mise" ]] && break
			mise=
		done
		[[ -n "$mise" ]] && command=("$mise" exec --)
		if grep -qsE '^    rubocop \(' Gemfile.lock gems.locked; then
			command+=(bundle exec rubocop)
		else
			command+=(rubocop)
		fi
	fi
	"${command[@]}" "$@"
}

# Format the document (standard input) by running RuboCop: prints it
# formatted and exits 202 (replacing the document), exits 200 when there is
# nothing to change, or shows why it could not be formatted. The options in
# TM_RUBOCOP_OPTIONS are added.
ruby_rubocop_format () { # input file
	local input=$1 path=${TM_FILEPATH:-${TM_DIRECTORY:-${TMPDIR:-/tmp}}/untitled.rb} options=() editor=(--editor-mode) status reason
	eval "options=(${TM_RUBOCOP_OPTIONS:-})"

	# --editor-mode (RuboCop 1.61 and later) leaves what is being written, such
	# as a variable not used yet, as ruby-lsp does.
	while true; do
		ruby_rubocop --autocorrect "${editor[@]}" --stdin "$path" --stderr --format emacs --force-exclusion "${options[@]}" < "$input" > "$input.formatted" 2> "$input.errors"
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
	cat "$input.formatted"
	exit 202
}

# Format the document (standard input) with RuboCop: through ruby-lsp, or
# else by running RuboCop.
ruby_format_document () {
	local tmp
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/textmate-rubocop.XXXXXX") || exit 1
	trap "rm -rf $(printf '%q' "$tmp")" EXIT # Expanded now, as traps run once locals are gone
	cat > "$tmp/input"

	ruby_format_with_language_server
	(( $? == 2 )) || exit 200
	ruby_rubocop_format "$tmp/input"
}
