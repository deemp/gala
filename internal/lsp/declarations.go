package lsp

import (
	"regexp"
	"strings"

	"github.com/owenrumney/go-lsp/lsp"
)

// declaration is a top-level declaration found by scanning a file's text.
type declaration struct {
	name string
	kind lsp.SymbolKind
	// container is the receiver type of a method or the sealed type of a
	// variant; empty for other declarations.
	container string
	line, col int // position of the name
	endLine   int // last line of the declaration, for its enclosing range
	variants  []declaration
}

var (
	// Top-level declarations start in column 0; anything indented is local.
	methodDeclRe   = regexp.MustCompile(`^func[ \t]*\(([^)]*)\)[ \t]*([A-Za-z_][A-Za-z0-9_]*)`)
	funcDeclRe     = regexp.MustCompile(`^func[ \t]+([A-Za-z_][A-Za-z0-9_]*)`)
	sealedDeclRe   = regexp.MustCompile(`^sealed[ \t]+type[ \t]+([A-Za-z_][A-Za-z0-9_]*)`)
	typeDeclRe     = regexp.MustCompile(`^type[ \t]+([A-Za-z_][A-Za-z0-9_]*)(?:\[[^\]]*\])?[ \t]*(struct|interface)?`)
	structDeclRe   = regexp.MustCompile(`^struct[ \t]+([A-Za-z_][A-Za-z0-9_]*)`)
	bindingDeclRe  = regexp.MustCompile(`^(?:embed[ \t]+)?(?:val|var)[ \t]+([A-Za-z_][A-Za-z0-9_]*)`)
	sealedCaseRe   = regexp.MustCompile(`^[ \t]+case[ \t]+([A-Za-z_][A-Za-z0-9_]*)`)
	receiverTypeRe = regexp.MustCompile(`([A-Za-z_][A-Za-z0-9_]*)(?:\[[^\]]*\])?[ \t]*$`)
)

// scanDeclarations lists the top-level declarations of GALA source text in
// source order. It reads the text line by line instead of parsing it, so it is
// cheap enough to run over a whole workspace and still works on a file that
// does not parse. Lines inside block comments and raw strings are skipped.
func scanDeclarations(text string) []declaration {
	lines := splitLines(text)
	code := codeLineStarts(lines)

	var decls []declaration
	for i := 0; i < len(lines); i++ {
		if !code[i] {
			continue
		}
		line := lines[i]
		d, ok := topLevelDeclaration(line)
		if !ok {
			continue
		}
		d.line = i
		d.endLine = i
		if strings.HasSuffix(strings.TrimSpace(stripLineComment(line)), "{") {
			d.endLine = closingBraceLine(lines, code, i)
		}
		if d.kind == lsp.SymbolKindEnum {
			for j := i + 1; j <= d.endLine; j++ {
				if m := sealedCaseRe.FindStringSubmatchIndex(lines[j]); m != nil && code[j] {
					d.variants = append(d.variants, declaration{
						name:      lines[j][m[2]:m[3]],
						kind:      lsp.SymbolKindEnumMember,
						container: d.name,
						line:      j,
						col:       m[2],
						endLine:   j,
					})
				}
			}
		}
		decls = append(decls, d)
	}
	return decls
}

// topLevelDeclaration recognizes a top-level declaration on one line. The returned
// declaration has its name, kind, container and column set.
func topLevelDeclaration(line string) (declaration, bool) {
	if m := methodDeclRe.FindStringSubmatchIndex(line); m != nil {
		receiver := ""
		if r := receiverTypeRe.FindStringSubmatch(line[m[2]:m[3]]); r != nil {
			receiver = r[1]
		}
		return declaration{name: line[m[4]:m[5]], kind: lsp.SymbolKindMethod, container: receiver, col: m[4]}, true
	}
	if m := funcDeclRe.FindStringSubmatchIndex(line); m != nil {
		return declaration{name: line[m[2]:m[3]], kind: lsp.SymbolKindFunction, col: m[2]}, true
	}
	if m := sealedDeclRe.FindStringSubmatchIndex(line); m != nil {
		return declaration{name: line[m[2]:m[3]], kind: lsp.SymbolKindEnum, col: m[2]}, true
	}
	if m := typeDeclRe.FindStringSubmatchIndex(line); m != nil {
		kind := lsp.SymbolKindClass // a type alias or defined type
		if m[4] >= 0 {
			if line[m[4]:m[5]] == "interface" {
				kind = lsp.SymbolKindInterface
			} else {
				kind = lsp.SymbolKindStruct
			}
		}
		return declaration{name: line[m[2]:m[3]], kind: kind, col: m[2]}, true
	}
	if m := structDeclRe.FindStringSubmatchIndex(line); m != nil {
		return declaration{name: line[m[2]:m[3]], kind: lsp.SymbolKindStruct, col: m[2]}, true
	}
	if m := bindingDeclRe.FindStringSubmatchIndex(line); m != nil {
		return declaration{name: line[m[2]:m[3]], kind: lsp.SymbolKindVariable, col: m[2]}, true
	}
	return declaration{}, false
}

// codeLineStarts reports, for each line, whether it begins outside a block
// comment and outside a raw (backtick) string.
func codeLineStarts(lines []string) []bool {
	starts := make([]bool, len(lines))
	inComment, inRaw := false, false
	for i, line := range lines {
		starts[i] = !inComment && !inRaw
		for j := 0; j < len(line); j++ {
			switch {
			case inComment:
				if strings.HasPrefix(line[j:], "*/") {
					inComment = false
					j++
				}
			case inRaw:
				if line[j] == '`' {
					inRaw = false
				}
			case strings.HasPrefix(line[j:], "//"):
				j = len(line)
			case strings.HasPrefix(line[j:], "/*"):
				inComment = true
				j++
			case line[j] == '`':
				inRaw = true
			case line[j] == '"':
				j = skipQuoted(line, j)
			}
		}
	}
	return starts
}

// skipQuoted returns the index of the quote closing the string opened at start,
// or the last index of the line when it is unterminated.
func skipQuoted(line string, start int) int {
	for j := start + 1; j < len(line); j++ {
		switch line[j] {
		case '\\':
			j++
		case '"':
			return j
		}
	}
	return len(line) - 1
}

// closingBraceLine returns the line of the column-0 `}` that closes the
// declaration opened on line start, or start when there is none.
func closingBraceLine(lines []string, code []bool, start int) int {
	for j := start + 1; j < len(lines); j++ {
		if code[j] && strings.HasPrefix(lines[j], "}") {
			return j
		}
	}
	return start
}

// selectionRange is the range of a declaration's name.
func (d declaration) selectionRange() lsp.Range {
	return lsp.Range{
		Start: lsp.Position{Line: d.line, Character: d.col},
		End:   lsp.Position{Line: d.line, Character: d.col + len(d.name)},
	}
}

// fullRange spans the declaration from the start of its first line to the end
// of its last line.
func (d declaration) fullRange(lines []string) lsp.Range {
	end := len(lines[d.endLine])
	return lsp.Range{
		Start: lsp.Position{Line: d.line, Character: 0},
		End:   lsp.Position{Line: d.endLine, Character: end},
	}
}
